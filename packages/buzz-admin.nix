# SPDX-FileCopyrightText: 2026 Steve Schoettler
#
# SPDX-License-Identifier: Apache-2.0

{ callPackage }:

callPackage ./buzz-component.nix {
  component = "buzz-admin";
  binary = "buzz-admin";
  description = "Operator CLI for Buzz relay administration";
}
