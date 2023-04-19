// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/widgets.dart';

import 'configuration.dart';
import 'delegate.dart';
import 'information_provider.dart';
import 'logging.dart';
import 'matching.dart';
import 'misc/inherited_router.dart';
import 'parser.dart';
import 'typedefs.dart';

/// The route configuration for the app.
///
/// The `routes` list specifies the top-level routes for the app. It must not be
/// empty and must contain an [GoRouter] to match `/`.
///
/// See the [Get
/// started](https://github.com/flutter/packages/blob/main/packages/go_router/example/lib/main.dart)
/// example, which shows an app with a simple route configuration.
///
/// The [redirect] callback allows the app to redirect to a new location.
/// Alternatively, you can specify a redirect for an individual route using
/// [GoRoute.redirect]. If [BuildContext.dependOnInheritedWidgetOfExactType] is
/// used during the redirection (which is how `of` methods are usually
/// implemented), a re-evaluation will be triggered when the [InheritedWidget]
/// changes.
///
/// See also:
/// * [Configuration](https://pub.dev/documentation/go_router/latest/topics/Configuration-topic.html)
/// * [GoRoute], which provides APIs to define the routing table.
/// * [examples](https://github.com/flutter/packages/tree/main/packages/go_router/example),
///    which contains examples for different routing scenarios.
/// {@category Get started}
/// {@category Upgrading}
/// {@category Configuration}
/// {@category Navigation}
/// {@category Redirection}
/// {@category Web}
/// {@category Deep linking}
/// {@category Error handling}
/// {@category Named routes}
class GoRouter extends ChangeNotifier implements RouterConfig<RouteMatchList> {
  /// Default constructor to configure a GoRouter with a routes builder
  /// and an error page builder.
  ///
  /// The `routes` must not be null and must contain an [GoRouter] to match `/`.
  GoRouter({
    required List<RouteBase> routes,
    // TODO(johnpryan): Change to a route, improve error API
    // See https://github.com/flutter/flutter/issues/108144
    GoRouterPageBuilder? errorPageBuilder,
    GoRouterWidgetBuilder? errorBuilder,
    GoRouterRedirect? redirect,
    Listenable? refreshListenable,
    int redirectLimit = 5,
    bool routerNeglect = false,
    String? initialLocation,
    Object? initialExtra,
    List<NavigatorObserver>? observers,
    bool debugLogDiagnostics = false,
    GlobalKey<NavigatorState>? navigatorKey,
    String? restorationScopeId,
  })  : backButtonDispatcher = RootBackButtonDispatcher(),
        assert(
          initialExtra == null || initialLocation != null,
          'initialLocation must be set in order to use initialExtra',
        ) {
    setLogging(enabled: debugLogDiagnostics);
    WidgetsFlutterBinding.ensureInitialized();

    navigatorKey ??= GlobalKey<NavigatorState>();

    _routeConfiguration = RouteConfiguration(
      routes: routes,
      topRedirect: redirect ?? (_, __) => null,
      redirectLimit: redirectLimit,
      navigatorKey: navigatorKey,
    );

    _routeInformationParser = GoRouteInformationParser(
      configuration: _routeConfiguration,
      debugRequireGoRouteInformationProvider: true,
    );

    _routeInformationProvider = GoRouteInformationProvider(
      initialRouteInformation: RouteInformation(
        // TODO(chunhtai): remove this ignore and migrate the code
        // https://github.com/flutter/flutter/issues/124045.
        // ignore: deprecated_member_use
        location: _effectiveInitialLocation(initialLocation),
        state: initialExtra,
      ),
      refreshListenable: refreshListenable,
    );

    _routerDelegate = GoRouterDelegate(
      configuration: _routeConfiguration,
      errorPageBuilder: errorPageBuilder,
      errorBuilder: errorBuilder,
      routerNeglect: routerNeglect,
      observers: <NavigatorObserver>[
        ...observers ?? <NavigatorObserver>[],
      ],
      restorationScopeId: restorationScopeId,
      // wrap the returned Navigator to enable GoRouter.of(context).go() et al,
      // allowing the caller to wrap the navigator themselves
      builderWithNav: (BuildContext context, Widget child) =>
          InheritedGoRouter(goRouter: this, child: child),
    );
    _routerDelegate.addListener(_handleStateMayChange);

    assert(() {
      log.info('setting initial location $initialLocation');
      return true;
    }());
  }

  late final RouteConfiguration _routeConfiguration;
  late final GoRouteInformationParser _routeInformationParser;
  late final GoRouterDelegate _routerDelegate;
  late final GoRouteInformationProvider _routeInformationProvider;

  @override
  final BackButtonDispatcher backButtonDispatcher;

  /// The router delegate. Provide this to the MaterialApp or CupertinoApp's
  /// `.router()` constructor
  @override
  GoRouterDelegate get routerDelegate => _routerDelegate;

  /// The route information provider used by [GoRouter].
  @override
  GoRouteInformationProvider get routeInformationProvider =>
      _routeInformationProvider;

  /// The route information parser used by [GoRouter].
  @override
  GoRouteInformationParser get routeInformationParser =>
      _routeInformationParser;

  /// The route configuration. Used for testing.
  // TODO(johnpryan): Remove this, integration tests shouldn't need access
  @visibleForTesting
  RouteConfiguration get routeConfiguration => _routeConfiguration;

  /// Gets the current location.
  // TODO(chunhtai): deprecates this once go_router_builder is migrated to
  // GoRouterState.of.
  String get location => _location;
  String _location = '/';

  /// Returns `true` if there is at least two or more route can be pop.
  bool canPop() => _routerDelegate.canPop();

  void _handleStateMayChange() {
    final String newLocation;
    if (routerDelegate.currentConfiguration.isNotEmpty &&
        routerDelegate.currentConfiguration.matches.last
            is ImperativeRouteMatch) {
      newLocation = (routerDelegate.currentConfiguration.matches.last
              as ImperativeRouteMatch<Object?>)
          .matches
          .uri
          .toString();
    } else {
      newLocation = _routerDelegate.currentConfiguration.uri.toString();
    }
    if (_location != newLocation) {
      _location = newLocation;
      notifyListeners();
    }
  }

  /// Get a location from route name and parameters.
  /// This is useful for redirecting to a named location.
  String namedLocation(
    String name, {
    Map<String, String> params = const <String, String>{},
    Map<String, dynamic> queryParams = const <String, dynamic>{},
  }) =>
      _routeInformationParser.configuration.namedLocation(
        name,
        params: params,
        queryParams: queryParams,
      );

  /// Navigate to a URI location w/ optional query parameters, e.g.
  /// `/family/f2/person/p1?color=blue`
  void go(String location, {Object? extra}) {
    assert(() {
      log.info('going to $location');
      return true;
    }());
    _routeInformationProvider.value =
        // TODO(chunhtai): remove this ignore and migrate the code
        // https://github.com/flutter/flutter/issues/124045.
        // ignore: deprecated_member_use
        RouteInformation(location: location, state: extra);
  }

  /// Navigate to a named route w/ optional parameters, e.g.
  /// `name='person', params={'fid': 'f2', 'pid': 'p1'}`
  /// Navigate to the named route.
  void goNamed(
    String name, {
    Map<String, String> params = const <String, String>{},
    Map<String, dynamic> queryParams = const <String, dynamic>{},
    Object? extra,
  }) =>
      go(
        namedLocation(name, params: params, queryParams: queryParams),
        extra: extra,
      );

  /// Push a URI location onto the page stack w/ optional query parameters, e.g.
  /// `/family/f2/person/p1?color=blue`.
  ///
  /// See also:
  /// * [pushReplacement] which replaces the top-most page of the page stack and
  ///   always use a new page key.
  /// * [replace] which replaces the top-most page of the page stack but treats
  ///   it as the same page. The page key will be reused. This will preserve the
  ///   state and not run any page animation.
  Future<T?> push<T extends Object?>(String location, {Object? extra}) async {
    assert(() {
      log.info('pushing $location');
      return true;
    }());
    final RouteMatchList matches =
        await _routeInformationParser.parseRouteInformationWithDependencies(
      // TODO(chunhtai): remove this ignore and migrate the code
      // https://github.com/flutter/flutter/issues/124045.
      // ignore: deprecated_member_use
      RouteInformation(location: location, state: extra),
      // TODO(chunhtai): avoid accessing the context directly through global key.
      // https://github.com/flutter/flutter/issues/99112
      _routerDelegate.navigatorKey.currentContext!,
    );

    return _routerDelegate.push<T>(matches);
  }

  /// Push a named route onto the page stack w/ optional parameters, e.g.
  /// `name='person', params={'fid': 'f2', 'pid': 'p1'}`
  Future<T?> pushNamed<T extends Object?>(
    String name, {
    Map<String, String> params = const <String, String>{},
    Map<String, dynamic> queryParams = const <String, dynamic>{},
    Object? extra,
  }) =>
      push<T>(
        namedLocation(name, params: params, queryParams: queryParams),
        extra: extra,
      );

  /// Replaces the top-most page of the page stack with the given URL location
  /// w/ optional query parameters, e.g. `/family/f2/person/p1?color=blue`.
  ///
  /// See also:
  /// * [go] which navigates to the location.
  /// * [push] which pushes the given location onto the page stack.
  /// * [replace] which replaces the top-most page of the page stack but treats
  ///   it as the same page. The page key will be reused. This will preserve the
  ///   state and not run any page animation.
  void pushReplacement(String location, {Object? extra}) {
    routeInformationParser
        .parseRouteInformationWithDependencies(
      // TODO(chunhtai): remove this ignore and migrate the code
      // https://github.com/flutter/flutter/issues/124045.
      // ignore: deprecated_member_use
      RouteInformation(location: location, state: extra),
      // TODO(chunhtai): avoid accessing the context directly through global key.
      // https://github.com/flutter/flutter/issues/99112
      _routerDelegate.navigatorKey.currentContext!,
    )
        .then<void>((RouteMatchList matchList) {
      routerDelegate.pushReplacement(matchList);
    });
  }

  /// Replaces the top-most page of the page stack with the named route w/
  /// optional parameters, e.g. `name='person', params={'fid': 'f2', 'pid':
  /// 'p1'}`.
  ///
  /// See also:
  /// * [goNamed] which navigates a named route.
  /// * [pushNamed] which pushes a named route onto the page stack.
  void pushReplacementNamed(
    String name, {
    Map<String, String> params = const <String, String>{},
    Map<String, dynamic> queryParams = const <String, dynamic>{},
    Object? extra,
  }) {
    pushReplacement(
      namedLocation(name, params: params, queryParams: queryParams),
      extra: extra,
    );
  }

  /// Replaces the top-most page of the page stack with the given one but treats
  /// it as the same page.
  ///
  /// The page key will be reused. This will preserve the state and not run any
  /// page animation.
  ///
  /// See also:
  /// * [push] which pushes the given location onto the page stack.
  /// * [pushReplacement] which replaces the top-most page of the page stack but
  ///   always uses a new page key.
  void replace(String location, {Object? extra}) {
    routeInformationParser
        .parseRouteInformationWithDependencies(
      // TODO(chunhtai): remove this ignore and migrate the code
      // https://github.com/flutter/flutter/issues/124045.
      // ignore: deprecated_member_use
      RouteInformation(location: location, state: extra),
      // TODO(chunhtai): avoid accessing the context directly through global key.
      // https://github.com/flutter/flutter/issues/99112
      _routerDelegate.navigatorKey.currentContext!,
    )
        .then<void>((RouteMatchList matchList) {
      routerDelegate.replace(matchList);
    });
  }

  /// Replaces the top-most page with the named route and optional parameters,
  /// preserving the page key.
  ///
  /// This will preserve the state and not run any page animation. Optional
  /// parameters can be providded to the named route, e.g. `name='person',
  /// params={'fid': 'f2', 'pid': 'p1'}`.
  ///
  /// See also:
  /// * [pushNamed] which pushes the given location onto the page stack.
  /// * [pushReplacementNamed] which replaces the top-most page of the page
  ///   stack but always uses a new page key.
  void replaceNamed(
    String name, {
    Map<String, String> params = const <String, String>{},
    Map<String, dynamic> queryParams = const <String, dynamic>{},
    Object? extra,
  }) {
    replace(
      namedLocation(name, params: params, queryParams: queryParams),
      extra: extra,
    );
  }

  /// Pop the top-most route off the current screen.
  ///
  /// If the top-most route is a pop up or dialog, this method pops it instead
  /// of any GoRoute under it.
  void pop<T extends Object?>([T? result]) {
    assert(() {
      log.info('popping $location');
      return true;
    }());
    _routerDelegate.pop<T>(result);
  }

  /// Refresh the route.
  void refresh() {
    assert(() {
      log.info('refreshing $location');
      return true;
    }());
    _routeInformationProvider.notifyListeners();
  }

  /// Find the current GoRouter in the widget tree.
  static GoRouter of(BuildContext context) {
    final InheritedGoRouter? inherited =
        context.dependOnInheritedWidgetOfExactType<InheritedGoRouter>();
    assert(inherited != null, 'No GoRouter found in context');
    return inherited!.goRouter;
  }

  /// The current GoRouter in the widget tree, if any.
  static GoRouter? maybeOf(BuildContext context) {
    final InheritedGoRouter? inherited =
        context.dependOnInheritedWidgetOfExactType<InheritedGoRouter>();
    return inherited?.goRouter;
  }

  @override
  void dispose() {
    _routeInformationProvider.dispose();
    _routerDelegate.removeListener(_handleStateMayChange);
    _routerDelegate.dispose();
    super.dispose();
  }

  String _effectiveInitialLocation(String? initialLocation) {
    final String platformDefault =
        WidgetsBinding.instance.platformDispatcher.defaultRouteName;
    if (initialLocation == null) {
      return platformDefault;
    } else if (platformDefault == '/') {
      return initialLocation;
    } else {
      return platformDefault;
    }
  }
}
