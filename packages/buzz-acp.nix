# SPDX-FileCopyrightText: 2026 Steve Schoettler
#
# SPDX-License-Identifier: Apache-2.0

{
  callPackage,
  bash,
  git,
  python3,
}:

callPackage ./buzz-component.nix {
  component = "buzz-acp";
  binary = "buzz-acp";
  description = "Buzz ACP harness for headless agents";
  # tests/git_bootstrap.rs runs real git inside its fake adapter, and
  # tests/run_task.rs drives a Python fake agent (tests/fixtures/task_agent.py).
  extraNativeCheckInputs = [
    git
    python3
  ];
  # Test fixtures write fake adapter scripts with #!/bin/bash and
  # #!/usr/bin/env bash shebangs, neither of which exists in the build sandbox
  # (spawning them fails with ENOENT). Point them at bash from the store.
  # git_bootstrap.rs also clears the harness environment, which drops
  # SSL_CERT_FILE; the sandbox has no system CA store, so pass it through.
  postPatch = ''
    substituteInPlace crates/buzz-acp/src/pool/pi_prompt_tests.rs \
      --replace-fail '#!/bin/bash' '#!${bash}/bin/bash'
    substituteInPlace crates/buzz-acp/src/acp.rs \
      --replace-fail '#!/usr/bin/env bash' '#!${bash}/bin/bash'
    substituteInPlace crates/buzz-acp/tests/git_bootstrap.rs \
      --replace-fail \
        '.env("PATH", std::env::var_os("PATH").unwrap_or_default())' \
        '.env("PATH", std::env::var_os("PATH").unwrap_or_default()).env("SSL_CERT_FILE", std::env::var_os("SSL_CERT_FILE").unwrap_or_default())'
  '';
}
