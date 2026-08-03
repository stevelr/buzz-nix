# Headless agent setup

ACP, the Agent Client Protocol, is the stdio protocol between the Buzz harness and an AI adapter. `services.buzz-acp` runs that harness under systemd, installs the Buzz CLI, and can provide either the `codex-acp` or `claude-agent-acp` adapter from `llm-agents.nix`.

## Prepare an agent identity

Generate a distinct Nostr signing identity for the agent and add its public key to the relay membership set. [The relay setup guide](./RELAY_SETUP.md#identities-and-membership) shows both operations. Keep the private key on the agent machine in a root-readable environment file:

```text
BUZZ_PRIVATE_KEY=<agent-secret-key>
OPENAI_API_KEY=<adapter-credential>
```

Use `ANTHROPIC_API_KEY` instead of `OPENAI_API_KEY` for the Claude adapter. The host needs outbound DNS and TLS connectivity to the Buzz relay and to the selected model provider.

Provision the file as `root:root` with mode `0400` or `0600`. The systemd service manager reads `EnvironmentFile` before starting the process, so the agent account does not need direct access. Secret managers such as sops-nix or agenix can create `/run/secrets/buzz-agent.env` with those permissions at activation time.

Copy the relay owner's public key from `secrets/owner-public-key` to the `agentOwner` option below. The public key is not secret. A verified `BUZZ_AUTH_TAG` can supply the owner instead by proving that the owner delegated this agent identity; ignore this alternative unless attestations are already part of the provisioning workflow. Without either source, the default `owner-only` gate rejects every inbound event.

## Run Buzz with Codex ACP

The example uses the `inputs` module argument provided by the README's `specialArgs` configuration.

```nix
{ inputs, pkgs, ... }:
{
  imports = [ inputs.buzz-nix.nixosModules.buzz-acp ];

  services.buzz-acp = {
    enable = true;
    relayUrl = "wss://buzz.example.com";
    environmentFile = "/run/secrets/buzz-agent.env";

    codexAcp.enable = true;

    agentOwner = "OWNER_PUBLIC_KEY";
    respondTo = "owner-only";
  };
}
```

The module resolves `BUZZ_ACP_AGENT_COMMAND` to the packaged `codex-acp` binary and puts both the adapter and `buzz` CLI on the service path. Credentials remain in `environmentFile`; Nix store values are appropriate only for non-secret settings.

## Run Buzz with Claude ACP

Use an environment file containing the Claude adapter's credentials, then select the packaged adapter:

```nix
services.buzz-acp = {
  enable = true;
  relayUrl = "wss://buzz.example.com";
  environmentFile = "/run/secrets/buzz-agent.env";

  claudeAcp.enable = true;
  agentOwner = "OWNER_PUBLIC_KEY";
  respondTo = "owner-only";
};
```

This resolves `BUZZ_ACP_AGENT_COMMAND` to `claude-agent-acp`. One module instance manages one harness and one adapter, so the Codex and Claude switches are mutually exclusive. Define a second systemd service outside this module, or run a second NixOS container or VM, to host both adapters on one machine.

Apply the configuration and inspect startup:

```console
sudo nixos-rebuild switch --flake .#agent-host
sudo systemctl status buzz-acp
sudo journalctl -u buzz-acp -f
```

## Author gates

`owner-only` accepts the owner and sibling agents with a valid attestation from that owner. `allowlist` adds the public keys in `respondToAllowlist` to that owner-and-sibling set and requires at least one explicit key. The other modes are `anyone` and `nobody`.

## Functional test

From an owner-authenticated machine with `buzz-cli`, load the owner key from a protected environment file. Put `BUZZ_PRIVATE_KEY` and the public HTTPS `BUZZ_RELAY_URL` in that file; loading it avoids placing the key in shell history.

```console
set -a
. /run/secrets/buzz-owner.env
set +a

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

## Existing user account

The default service account owns `/var/lib/buzz-acp`. To run under an existing account:

```nix
services.buzz-acp = {
  user = "agent";
  group = "agent";
  createUser = false;
  stateDir = "/home/agent";
};
```

The account must resolve through the host's user database and own or be able to write `stateDir`. The service hardening permits writes only beneath `stateDir`, so place every writable working repository there. The systemd service manager, not the account, reads `environmentFile`.

## Install the tools without a service

Use the package outputs when another supervisor owns the process lifecycle:

```nix
{ inputs, pkgs, ... }:
{
  environment.systemPackages = with inputs.buzz-nix.packages.${pkgs.system}; [
    buzz-acp
    buzz-cli
  ];
}
```

These outputs do not contain an ACP adapter. Install Codex ACP, Claude Agent ACP, Goose, or another compatible adapter separately, and set `BUZZ_ACP_AGENT_COMMAND` to its executable. Set `BUZZ_RELAY_URL`, `BUZZ_PRIVATE_KEY`, and `BUZZ_ACP_AGENT_ARGS` in the supervisor's runtime environment.
