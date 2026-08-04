<!--
SPDX-FileCopyrightText: 2026 Steve Schoettler

SPDX-License-Identifier: Apache-2.0
-->

# Headless agent setup

This guide shows how to run the buzz harness on a headless nixos server using ACP, the Agent Client Protocol.

Modes of operation:

```
buzz-acp <-> ACP protocol over stdio <-> codex-acp <-> codex
```

```
buzz-acp <-> ACP protocol over stdio <-> claude-agent-acp <-> claude
```

```
buzz-acp <-> ACP protocol over stdio
             <-> buzz-agent <-> OpenAI API <-> any OpenAI API-compatible model
```

`services.buzz-acp` runs the harness under systemd, installs the Buzz CLI, buzz-agent, and acp adapters, and invokes agents. You control all of these through buzz desktop or mobile apps.

## Prepare an agent identity

Generate a distinct agent keypair

```
nix run .#buzz-admin -- generate-key
```

and add its public key as a relay member as desscribed in [The relay setup guide](./RELAY_SETUP.md#identities-and-membership). Put the private key on the agent machine in a root-readable environment file:

```text
BUZZ_PRIVATE_KEY=<agent-secret-key>
```

Additional API keys or other environment variables needed by agents can be set either in this file or in the buzz app in the agent settings. If you have a claude code or codex subscription, it is not necessary to set api keys in the environment because you can authenticate those services through the buzz app.

Provision the file as `root:root` with mode `0400` or `0600`. The systemd service manager reads `EnvironmentFile` before starting the process, so the agent account does not need direct access. Secret managers such as sops-nix or agenix can create `/run/secrets/buzz-agent.env` with those permissions at activation time.

Copy the relay owner's public key from the relay server's `secrets/owner-public-key` to the `agentOwner` option below. This key is not secret so it's ok to be in the nix store.

## Configure Buzz

```nix
{ inputs, pkgs, ... }:
{
  imports = [ inputs.buzz-nix.nixosModules.buzz-acp ];

  services.buzz-acp = {
    enable = true;
    relayUrl = "wss://buzz.example.com";
    environmentFile = "/run/secrets/buzz-agent.env";

    codexAcp.enable = true;
    # claudeAcp.enable = true;

    agentOwner = "OWNER_PUBLIC_KEY";
    respondTo = "owner-only";

    # List other packages the agents need. These will be in the agents' PATH.
    # extraPackages = [ ];

    # Non-secret environment variables. Keep secrets in the buzz-agent.env file or configure as agent settings in the buzz app.
    # extraEnvironment = { };
  };
}
```

`owner-only` limits control of the agent to the owner. Change to `anyone` for unrestricted control, or, for a team, use `allowlist`, and set `respondToAllowlist` to a list of users' public keys.

The module sets the default `BUZZ_ACP_AGENT_COMMAND` to the packaged `codex-acp` or `claude-agent-acp`. It can be overridden on a per-agent basis within the buzz app. Keep credentials in `environmentFile`; Nix store values are appropriate only for non-secret settings.

Apply the configuration and inspect startup:

```console
sudo nixos-rebuild switch --flake .#agent-host
sudo systemctl status buzz-acp
sudo journalctl -u buzz-acp -f
```

## Functional test

From an owner-authenticated machine with `buzz-cli`, load the owner key from a protected environment file. Put `BUZZ_PRIVATE_KEY` and the public HTTPS `BUZZ_RELAY_URL` in that file; loading it avoids placing the key in shell history.

```console
set -a
. /run/secrets/buzz-owner.env
set +a
export RELAY_URL="wss://buzz.example.com"

buzz channels create --name agent-test --type stream --visibility private
buzz channels add-member --channel <channel-uuid> --pubkey <agent-public-key> --role bot
buzz messages send --channel <channel-uuid> \
  --content "@Agent report your status" --mention <agent-public-key>
```

Commands return JSON; use the channel UUID from `channels create` in the later calls. The service journal should show the accepted event, ACP turn, and reply. Relay membership does not grant private-channel access, so add the agent to each private channel it should monitor.

## Use another ACP agent

Disable the Codex adapter and provide an ACP-compatible command. Arguments use Buzz's comma-separated format:

```nix
services.buzz-acp = {
  enable = true;
  relayUrl = "wss://buzz.example.com";
  environmentFile = "/run/secrets/buzz-agent.env";

  codexAcp.enable = false;
  agentCommand = "goose";
  agentArgs = "acp";
  extraPackages = [ pkgs.goose-cli ];
};
```

For example, `agentArgs = ''-c,model="provider/model",acp'';` becomes three arguments. Values containing commas require an adapter-specific wrapper because Buzz uses commas as separators.

Use `extraPackages` for the adapter and any tools it launches. `extraEnvironment` carries non-secret tuning such as model names or timeout settings.

## Running as an existing user

The default configuration runs buzz-acp and agents under a unique user id. If you want the agents to access or modify your own files, change the user and group to existing user and group names and set `createUser = false`.

```nix
services.buzz-acp = {
  user = "alice";
  group = "users";
  createUser = false;
  stateDir = "/home/alice";
};
```

systemd service hardening permits writes only beneath `stateDir`, so place every writable working repository there. The systemd service manager reads `environmentFile`.
