#!/bin/bash
# Copyright 2013 The Flutter Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Exclusions
#
# cross_file
#   Custom tests need Chrome. (They run in linux-custom_package_tests)

dart pub global run flutter_plugin_tools custom-test \
   --packages-for-branch --log-timing \
   --exclude=cross_file
