// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/widgets.dart';
import 'package:stream_transform/stream_transform.dart';

import 'analyzer.dart';
import 'camera.dart';
import 'camera_info.dart';
import 'camera_selector.dart';
import 'camerax_library.g.dart';
import 'image_analysis.dart';
import 'image_capture.dart';
import 'image_proxy.dart';
import 'plane_proxy.dart';
import 'preview.dart';
import 'process_camera_provider.dart';
import 'surface.dart';
import 'system_services.dart';
import 'use_case.dart';

/// The Android implementation of [CameraPlatform] that uses the CameraX library.
class AndroidCameraCameraX extends CameraPlatform {
  /// Registers this class as the default instance of [CameraPlatform].
  static void registerWith() {
    CameraPlatform.instance = AndroidCameraCameraX();
  }

  /// The [ProcessCameraProvider] instance used to access camera functionality.
  @visibleForTesting
  ProcessCameraProvider? processCameraProvider;

  /// The [Camera] instance returned by the [processCameraProvider] when a [UseCase] is
  /// bound to the lifecycle of the camera it manages.
  @visibleForTesting
  Camera? camera;

  /// The [Preview] instance that can be configured to present a live camera preview.
  @visibleForTesting
  Preview? preview;

  bool _previewIsPaused = false;

  /// The [ImageCapture] instance that can be configured to capture a still image.
  @visibleForTesting
  ImageCapture? imageCapture;

  /// The [ImageAnalysis] instance that can be configured to analyze individual
  /// frames.
  ImageAnalysis? imageAnalysis;

  /// The [CameraSelector] used to configure the [processCameraProvider] to use
  /// the desired camera.
  @visibleForTesting
  CameraSelector? cameraSelector;

  /// The resolution preset used to create a camera that should be used for
  /// capturing still images and recording video.
  ResolutionPreset? _resolutionPreset;

  /// The controller we need to broadcast the different camera events.
  ///
  /// It is a `broadcast` because multiple controllers will connect to
  /// different stream views of this Controller.
  /// This is only exposed for test purposes. It shouldn't be used by clients of
  /// the plugin as it may break or change at any time.
  @visibleForTesting
  final StreamController<CameraEvent> cameraEventStreamController =
      StreamController<CameraEvent>.broadcast();

  /// The stream of camera events.
  Stream<CameraEvent> _cameraEvents(int cameraId) =>
      cameraEventStreamController.stream
          .where((CameraEvent event) => event.cameraId == cameraId);

  /// The controller we need to stream image data.
  @visibleForTesting
  StreamController<CameraImageData>? cameraImageDataStreamController;

  /// Conditional used to create detached instances for testing their
  /// callback methods.
  @visibleForTesting
  bool createDetachedCallbacks = false;

  /// Constant representing the multi-plane Android YUV 420 image format.
  ///
  /// See https://developer.android.com/reference/android/graphics/ImageFormat#YUV_420_888.
  static const int imageFormatYuv420_888 = 35;

  /// Constant representing the compressed JPEG image format.
  ///
  /// See https://developer.android.com/reference/android/graphics/ImageFormat#JPEG.
  static const int imageFormatJpeg = 256;

  /// Returns list of all available cameras and their descriptions.
  @override
  Future<List<CameraDescription>> availableCameras() async {
    final List<CameraDescription> cameraDescriptions = <CameraDescription>[];

    processCameraProvider ??= await ProcessCameraProvider.getInstance();
    final List<CameraInfo> cameraInfos =
        await processCameraProvider!.getAvailableCameraInfos();

    CameraLensDirection? cameraLensDirection;
    int cameraCount = 0;
    int? cameraSensorOrientation;
    String? cameraName;

    for (final CameraInfo cameraInfo in cameraInfos) {
      // Determine the lens direction by filtering the CameraInfo
      // TODO(gmackall): replace this with call to CameraInfo.getLensFacing when changes containing that method are available
      if ((await createCameraSelector(CameraSelector.lensFacingBack)
              .filter(<CameraInfo>[cameraInfo]))
          .isNotEmpty) {
        cameraLensDirection = CameraLensDirection.back;
      } else if ((await createCameraSelector(CameraSelector.lensFacingFront)
              .filter(<CameraInfo>[cameraInfo]))
          .isNotEmpty) {
        cameraLensDirection = CameraLensDirection.front;
      } else {
        //Skip this CameraInfo as its lens direction is unknown
        continue;
      }

      cameraSensorOrientation = await cameraInfo.getSensorRotationDegrees();
      cameraName = 'Camera $cameraCount';
      cameraCount++;

      cameraDescriptions.add(CameraDescription(
          name: cameraName,
          lensDirection: cameraLensDirection,
          sensorOrientation: cameraSensorOrientation));
    }

    return cameraDescriptions;
  }

  /// Creates an uninitialized camera instance and returns the camera ID.
  ///
  /// In the CameraX library, cameras are accessed by combining [UseCase]s
  /// to an instance of a [ProcessCameraProvider]. Thus, to create an
  /// unitialized camera instance, this method retrieves a
  /// [ProcessCameraProvider] instance.
  ///
  /// To return the camera ID, which is equivalent to the ID of the surface texture
  /// that a camera preview can be drawn to, a [Preview] instance is configured
  /// and bound to the [ProcessCameraProvider] instance.
  @override
  Future<int> createCamera(
    CameraDescription cameraDescription,
    ResolutionPreset? resolutionPreset, {
    bool enableAudio = false,
  }) async {
    // Must obtain proper permissions before attempting to access a camera.
    await requestCameraPermissions(enableAudio);

    // Save CameraSelector that matches cameraDescription.
    final int cameraSelectorLensDirection =
        _getCameraSelectorLensDirection(cameraDescription.lensDirection);
    final bool cameraIsFrontFacing =
        cameraSelectorLensDirection == CameraSelector.lensFacingFront;
    cameraSelector = createCameraSelector(cameraSelectorLensDirection);
    // Start listening for device orientation changes preceding camera creation.
    startListeningForDeviceOrientationChange(
        cameraIsFrontFacing, cameraDescription.sensorOrientation);

    // Retrieve a fresh ProcessCameraProvider instance.
    processCameraProvider ??= await ProcessCameraProvider.getInstance();
    processCameraProvider!.unbindAll();

    // Configure Preview instance.
    _resolutionPreset = resolutionPreset;
    final int targetRotation =
        _getTargetRotation(cameraDescription.sensorOrientation);
    final ResolutionInfo? previewTargetResolution =
        _getTargetResolutionForPreview(resolutionPreset);
    preview = createPreview(targetRotation, previewTargetResolution);
    final int flutterSurfaceTextureId = await preview!.setSurfaceProvider();

    // Configure ImageCapture instance.
    final ResolutionInfo? imageCaptureTargetResolution =
        _getTargetResolutionForImageCapture(_resolutionPreset);
    imageCapture = createImageCapture(null, imageCaptureTargetResolution);

    // Bind configured UseCases to ProcessCameraProvider instance & mark Preview
    // instance as bound but not paused.
    camera = await processCameraProvider!
        .bindToLifecycle(cameraSelector!, <UseCase>[preview!, imageCapture!]);
    _previewIsPaused = false;

    return flutterSurfaceTextureId;
  }

  /// Initializes the camera on the device.
  ///
  /// Since initialization of a camera does not directly map as an operation to
  /// the CameraX library, this method just retrieves information about the
  /// camera and sends a [CameraInitializedEvent].
  ///
  /// [imageFormatGroup] is used to specify the image format used for image
  /// streaming, but CameraX currently only supports YUV_420_888 (supported by
  /// Flutter) and RGBA (not supported by Flutter). CameraX uses YUV_420_888
  /// by default, so [imageFormatGroup] is not used.
  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {
    // Configure CameraInitializedEvent to send as representation of a
    // configured camera:
    // Retrieve preview resolution.
    if (preview == null) {
      // No camera has been created; createCamera must be called before initializeCamera.
      throw CameraException(
        'cameraNotFound',
        "Camera not found. Please call the 'create' method before calling 'initialize'",
      );
    }

    final ResolutionInfo previewResolutionInfo =
        await preview!.getResolutionInfo();

    // Retrieve exposure and focus mode configurations:
    // TODO(camsim99): Implement support for retrieving exposure mode configuration.
    // https://github.com/flutter/flutter/issues/120468
    const ExposureMode exposureMode = ExposureMode.auto;
    const bool exposurePointSupported = false;

    // TODO(camsim99): Implement support for retrieving focus mode configuration.
    // https://github.com/flutter/flutter/issues/120467
    const FocusMode focusMode = FocusMode.auto;
    const bool focusPointSupported = false;

    cameraEventStreamController.add(CameraInitializedEvent(
        cameraId,
        previewResolutionInfo.width.toDouble(),
        previewResolutionInfo.height.toDouble(),
        exposureMode,
        exposurePointSupported,
        focusMode,
        focusPointSupported));
  }

  /// Releases the resources of the accessed camera.
  ///
  /// [cameraId] not used.
  @override
  Future<void> dispose(int cameraId) async {
    preview?.releaseFlutterSurfaceTexture();
    processCameraProvider?.unbindAll();
  }

  /// The camera has been initialized.
  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) {
    return _cameraEvents(cameraId).whereType<CameraInitializedEvent>();
  }

  /// The camera experienced an error.
  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) {
    return SystemServices.cameraErrorStreamController.stream
        .map<CameraErrorEvent>((String errorDescription) {
      return CameraErrorEvent(cameraId, errorDescription);
    });
  }

  /// The ui orientation changed.
  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() {
    return SystemServices.deviceOrientationChangedStreamController.stream;
  }

  /// Pause the active preview on the current frame for the selected camera.
  ///
  /// [cameraId] not used.
  @override
  Future<void> pausePreview(int cameraId) async {
    _unbindUseCaseFromLifecycle(preview!);
    _previewIsPaused = true;
  }

  /// Resume the paused preview for the selected camera.
  ///
  /// [cameraId] not used.
  @override
  Future<void> resumePreview(int cameraId) async {
    await _bindPreviewToLifecycle();
    _previewIsPaused = false;
  }

  /// Returns a widget showing a live camera preview.
  @override
  Widget buildPreview(int cameraId) {
    return FutureBuilder<void>(
        future: _bindPreviewToLifecycle(),
        builder: (BuildContext context, AsyncSnapshot<void> snapshot) {
          switch (snapshot.connectionState) {
            case ConnectionState.none:
            case ConnectionState.waiting:
            case ConnectionState.active:
              // Do nothing while waiting for preview to be bound to lifecyle.
              return const SizedBox.shrink();
            case ConnectionState.done:
              return Texture(textureId: cameraId);
          }
        });
  }

  /// Captures an image and returns the file where it was saved.
  ///
  /// [cameraId] is not used.
  @override
  Future<XFile> takePicture(int cameraId) async {
    // TODO(camsim99): Add support for flash mode configuration.
    // https://github.com/flutter/flutter/issues/120715
    final String picturePath = await imageCapture!.takePicture();

    return XFile(picturePath);
  }

  /// A new streamed frame is available.
  ///
  /// Listening to this stream will start streaming, and canceling will stop.
  /// To temporarily stop receiving frames, cancel, then listen again later.
  /// Pausing/resuming is not supported, as pausing the stream would cause
  /// very high memory usage, and will throw an exception due to the
  /// implementation using a broadcast [StreamController], which does not
  /// support those operations.
  ///
  /// [cameraId] and [options] are not used.
  @override
  Stream<CameraImageData> onStreamedFrameAvailable(int cameraId,
      {CameraImageStreamOptions? options}) {
    cameraImageDataStreamController = StreamController<CameraImageData>(
      onListen: _onFrameStreamListen,
      onCancel: _onFrameStreamCancel,
    );
    return cameraImageDataStreamController!.stream;
  }

  // Methods for binding UseCases to the lifecycle of the camera controlled
  // by a ProcessCameraProvider instance:

  /// Binds [preview] instance to the camera lifecycle controlled by the
  /// [processCameraProvider].
  Future<void> _bindPreviewToLifecycle() async {
    final bool previewIsBound = await processCameraProvider!.isBound(preview!);
    if (previewIsBound || _previewIsPaused) {
      // Only bind if preview is not already bound or intentionally paused.
      return;
    }

    camera = await processCameraProvider!
        .bindToLifecycle(cameraSelector!, <UseCase>[preview!]);
  }

  /// Configures the [imageAnalysis] instance for image streaming and binds it
  /// to camera lifecycle controlled by the [processCameraProvider].
  Future<void> _configureAndBindImageAnalysisToLifecycle() async {
    if (imageAnalysis != null &&
        await processCameraProvider!.isBound(imageAnalysis!)) {
      // imageAnalysis already configured and bound to lifecycle.
      return;
    }

    // Create Analyzer that can read image data for image streaming.
    Future<void> analyze(ImageProxy imageProxy) async {
      final List<PlaneProxy> planes = await imageProxy.getPlanes();
      final List<CameraImagePlane> cameraImagePlanes = <CameraImagePlane>[];
      for (final PlaneProxy plane in planes) {
        cameraImagePlanes.add(CameraImagePlane(
            bytes: plane.buffer,
            bytesPerRow: plane.rowStride,
            bytesPerPixel: plane.pixelStride));
      }

      final int format = imageProxy.format;
      final CameraImageFormat cameraImageFormat = CameraImageFormat(
          _imageFormatGroupFromPlatformData(format),
          raw: format);

      final CameraImageData cameraImageData = CameraImageData(
          format: cameraImageFormat,
          planes: cameraImagePlanes,
          height: imageProxy.height,
          width: imageProxy.width);
      cameraImageDataStreamController?.add(cameraImageData);
      imageProxy.close();
    }

    final Analyzer analyzer = createDetachedCallbacks
        ? Analyzer.detached(analyze: analyze)
        : Analyzer(analyze: analyze);

    // TODO(camsim99): Support resolution configuration.
    // Defaults to YUV_420_888 image format.
    imageAnalysis = createImageAnalysis(null);
    imageAnalysis!.setAnalyzer(analyzer);

    // TODO(camsim99): Reset live camera state observers here when
    // https://github.com/flutter/packages/pull/3419 lands.
    camera = await processCameraProvider!
        .bindToLifecycle(cameraSelector!, <UseCase>[imageAnalysis!]);
  }

  /// Unbinds [useCase] from camera lifecycle controlled by the
  /// [processCameraProvider].
  Future<void> _unbindUseCaseFromLifecycle(UseCase useCase) async {
    final bool useCaseIsBound = await processCameraProvider!.isBound(useCase);
    if (!useCaseIsBound) {
      return;
    }

    processCameraProvider!.unbind(<UseCase>[useCase]);
  }

  // Methods for configuring image streaming:

  /// The [onListen] callback for the stream controller used for image
  /// streaming.
  void _onFrameStreamListen() {
    _configureAndBindImageAnalysisToLifecycle();
  }

  /// The [onCancel] callback for the stream controller used for image
  /// streaming.
  ///
  /// Removes the previously set analyzer on the [imageAnalysis] instance, since
  /// image information should no longer be streamed.
  FutureOr<void> _onFrameStreamCancel() async {
    imageAnalysis!.clearAnalyzer();
  }

  /// Converts between Android ImageFormat constants and [ImageFormatGroup]s.
  ///
  /// See https://developer.android.com/reference/android/graphics/ImageFormat.
  ImageFormatGroup _imageFormatGroupFromPlatformData(dynamic data) {
    switch (data) {
      case imageFormatYuv420_888: // android.graphics.ImageFormat.YUV_420_888
        return ImageFormatGroup.yuv420;
      case imageFormatJpeg: // android.graphics.ImageFormat.JPEG
        return ImageFormatGroup.jpeg;
    }

    return ImageFormatGroup.unknown;
  }

  // Methods for mapping Flutter camera constants to CameraX constants:

  /// Returns [CameraSelector] lens direction that maps to specified
  /// [CameraLensDirection].
  int _getCameraSelectorLensDirection(CameraLensDirection lensDirection) {
    switch (lensDirection) {
      case CameraLensDirection.front:
        return CameraSelector.lensFacingFront;
      case CameraLensDirection.back:
        return CameraSelector.lensFacingBack;
      case CameraLensDirection.external:
        return CameraSelector.lensFacingExternal;
    }
  }

  /// Returns [Surface] target rotation constant that maps to specified sensor
  /// orientation.
  int _getTargetRotation(int sensorOrientation) {
    switch (sensorOrientation) {
      case 90:
        return Surface.ROTATION_90;
      case 180:
        return Surface.ROTATION_180;
      case 270:
        return Surface.ROTATION_270;
      case 0:
        return Surface.ROTATION_0;
      default:
        throw ArgumentError(
            '"$sensorOrientation" is not a valid sensor orientation value');
    }
  }

  /// Returns [ResolutionInfo] that maps to the specified resolution preset for
  /// a camera preview.
  ResolutionInfo? _getTargetResolutionForPreview(ResolutionPreset? resolution) {
    // TODO(camsim99): Implement resolution configuration.
    // https://github.com/flutter/flutter/issues/120462
    return null;
  }

  /// Returns [ResolutionInfo] that maps to the specified resolution preset for
  /// image capture.
  ResolutionInfo? _getTargetResolutionForImageCapture(
      ResolutionPreset? resolution) {
    // TODO(camsim99): Implement resolution configuration.
    // https://github.com/flutter/flutter/issues/120462
    return null;
  }

  // Methods for calls that need to be tested:

  /// Requests camera permissions.
  @visibleForTesting
  Future<void> requestCameraPermissions(bool enableAudio) async {
    await SystemServices.requestCameraPermissions(enableAudio);
  }

  /// Subscribes the plugin as a listener to changes in device orientation.
  @visibleForTesting
  void startListeningForDeviceOrientationChange(
      bool cameraIsFrontFacing, int sensorOrientation) {
    SystemServices.startListeningForDeviceOrientationChange(
        cameraIsFrontFacing, sensorOrientation);
  }

  /// Returns a [CameraSelector] based on the specified camera lens direction.
  @visibleForTesting
  CameraSelector createCameraSelector(int cameraSelectorLensDirection) {
    switch (cameraSelectorLensDirection) {
      case CameraSelector.lensFacingFront:
        return CameraSelector.getDefaultFrontCamera();
      case CameraSelector.lensFacingBack:
        return CameraSelector.getDefaultBackCamera();
      default:
        return CameraSelector(lensFacing: cameraSelectorLensDirection);
    }
  }

  /// Returns a [Preview] configured with the specified target rotation and
  /// resolution.
  @visibleForTesting
  Preview createPreview(int targetRotation, ResolutionInfo? targetResolution) {
    return Preview(
        targetRotation: targetRotation, targetResolution: targetResolution);
  }

  /// Returns an [ImageCapture] configured with specified flash mode and
  /// target resolution.
  @visibleForTesting
  ImageCapture createImageCapture(
      int? flashMode, ResolutionInfo? targetResolution) {
    return ImageCapture(
        targetFlashMode: flashMode, targetResolution: targetResolution);
  }

  /// Returns an [ImageAnalysis] configured with specified target resolution.
  @visibleForTesting
  ImageAnalysis createImageAnalysis(ResolutionInfo? targetResolution) {
    return ImageAnalysis(targetResolution: targetResolution);
  }
}
