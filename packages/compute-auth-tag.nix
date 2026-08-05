# SPDX-FileCopyrightText: 2026 Steve Schoettler
#
# SPDX-License-Identifier: Apache-2.0

{ callPackage }:

callPackage ./buzz-component.nix {
  component = "buzz-sdk";
  example = "compute_auth_tag";
  binary = "compute-auth-tag";
  pname = "compute-auth-tag";
  description = "Compute a NIP-OA owner attestation for an agent keypair.";

  # The example is a provisioning helper; the buzz-sdk test suite is unrelated
  # to it and only slows the build.
  doCheck = false;
}
