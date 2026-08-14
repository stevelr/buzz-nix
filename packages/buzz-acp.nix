# SPDX-FileCopyrightText: 2026 Steve Schoettler
#
# SPDX-License-Identifier: Apache-2.0

{ callPackage }:

callPackage ./buzz-component.nix {
  component = "buzz-acp";
  binary = "buzz-acp";
  description = "Buzz ACP harness for headless agents";
  # This test writes outside the build sandbox and fails with ENOENT (acp.rs:2982).
  checkFlags = [
    "--skip=acp::tests::claude_named_adapter_wire_lifecycle_records_prompt_and_cost"
  ];
}
