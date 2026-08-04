# SPDX-FileCopyrightText: 2026 Steve Schoettler
#
# SPDX-License-Identifier: Apache-2.0

{ callPackage }:

callPackage ./buzz-component.nix {
  component = "buzz-cli";
  binary = "buzz";
  description = "Command-line client for Buzz";
}
