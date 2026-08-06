# SPDX-FileCopyrightText: 2026 Steve Schoettler
#
# SPDX-License-Identifier: Apache-2.0

{ callPackage }:

callPackage ./buzz-component.nix {
  component = "buzz-pair-relay";
  binary = "buzz-pair-relay";
  description = "Buzz ephemeral device-pairing relay";
  # Shares the relay suites' need for live backing services.
  doCheck = false;
}
