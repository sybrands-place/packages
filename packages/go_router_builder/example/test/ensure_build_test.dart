// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

@Tags(<String>['presubmit-only'])
import 'package:build_verify/build_verify.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'ensure_build',
    () => expectBuildClean(
      packageRelativeDirectory: 'packages/go_router_builder/example',
    ),
    timeout: const Timeout.factor(3),
  );
}
