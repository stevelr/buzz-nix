# SPDX-FileCopyrightText: 2026 Steve Schoettler
#
# SPDX-License-Identifier: Apache-2.0

{ callPackage }:

callPackage ./buzz-component.nix {
  component = "buzz-agent";
  binary = "buzz-agent";
  description = "Minimal, unbreakable ACP-compliant LLM agent.";

  # intermittent test failures due to race conditions in tests
  # https://github.com/block/buzz/issues/4945
  # https://github.com/block/buzz/issues/4942
  # https://github.com/block/buzz/issues/4939
  doCheck = false;
}
