# SPDX-FileCopyrightText: 2026 Steve Schoettler
#
# SPDX-License-Identifier: Apache-2.0

{ callPackage }:

callPackage ./buzz-component.nix {
  component = "buzz-relay";
  binary = "buzz-relay";
  description = "Buzz WebSocket relay";
  # Upstream's relay suites require live PostgreSQL, Redis, and S3 services.
  # The NixOS module checks exercise the assembled service configuration.
  doCheck = false;
}
