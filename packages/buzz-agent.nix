# SPDX-FileCopyrightText: 2026 Steve Schoettler
#
# SPDX-License-Identifier: Apache-2.0

{ callPackage }:

callPackage ./buzz-component.nix {
  component = "buzz-agent";
  binary = "buzz-agent";
  description = "Minimal, unbreakable ACP-compliant LLM agent.";
}
