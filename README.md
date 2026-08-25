<!--
SPDX-FileCopyrightText: 2026 Steve Schoettler

SPDX-License-Identifier: Apache-2.0
-->

# buzz-nix

`buzz-nix` makes [Buzz](https://github.com/block/buzz) self-hosted relay server and agents available as reusable NixOS modules. The relay server runs on a nixos host or in a self-contained systemd-nspawn container. Agents run with `buzz-acp` and can run ACP (Agent-Client-Protocol) adapters or OpenAI API-compatible models. Codex and Claude ACP adapters are included.

## Choose a deployment

- A relay host imports `nixosModules.buzz-relay` and follows [RELAY_SETUP.md](./RELAY_SETUP.md). The relay module runs the buzz-relay server, postgres, minio, and an optional ferron reverse proxy.

- An agent host that connects to an existing relay imports `nixosModules.buzz-acp` and follows [HEADLESS_AGENT_SETUP.md](./HEADLESS_AGENT_SETUP.md). It does not need to run a relay.

The agent module can publish an attested profile and agent-directory record
before starting the harness. Registration is opt-in because its
`BUZZ_AUTH_TAG` must be created by the owner and supplied outside the Nix
store.

## Add the flake

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  inputs.buzz-nix = {
    url = "github:stevelr/buzz-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ nixpkgs, buzz-nix, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit inputs; };
      modules = [
        buzz-nix.nixosModules.buzz-relay # for relay server
        buzz-nix.nixosModules.buzz-acp # for agents
        ./configuration.nix
      ];
    };
  };
}
```

Setting `services.buzz-relay.container.enable = false` runs the service bundle directly on its NixOS host. If the host already runs a PostgreSQL service, container should be enabled so the postgres services don't conflict.

## Updating buzz

An updater script is provided to simplify updating to new buzz-desktop release versions. This script updates all buzz- related package versions, package hashes, and cargo hashes, and rebuilds the packages,

```shell
# Update versions and hashes, and rebuild buzz packages.
scripts/update-buzz-desktop
```

The script requires python >= 3.9 and nix flakes enabled.
Set `GITHUB_TOKEN` or `GH_TOKEN` for authenticated GitHub API requests.

If there are any build problems, it rolls back to the previous versions.
There are some intermittent test failures due to race conditions in 0.5.5
([1](https://github.com/block/buzz/issues/4945),[2](https://github.com/block/buzz/issues/4942), [3](https://github.com/block/buzz/issues/4939)), so if you encounter a build error, it might succeed on a second try.

After rebuilding, restart the services.

```shell
sudo systemctl restart container@buzz-relay.service
sudo systemctl restart buzz-acp.service
```
