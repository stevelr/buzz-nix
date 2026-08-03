# buzz-nix

`buzz-nix` packages the server and headless-agent components of [Buzz](https://github.com/block/buzz) and exposes reusable NixOS modules. It supports a complete relay in a native NixOS systemd-nspawn container and a `buzz-acp` service with optional Codex or Claude ACP adapters on x86-64 and AArch64 NixOS systems.

The flake exports these packages on x86-64 and AArch64 Linux:

- `buzz-cli`: the `buzz` command-line client.
- `buzz-acp`: the ACP harness for headless agents.
- `buzz-relay`: `buzz-relay`, `buzz-admin`, and the pairing sidecar.
- `ferron`: the optional reverse proxy and TLS terminator.
- `minio`: the server release used by the relay bundle.

Release revisions and fixed-output hashes live in `versions.json`. The package expressions read that file directly, so an update has one metadata source.

## Choose a deployment

- A relay host imports `nixosModules.buzz-relay-container` and follows [RELAY_SETUP.md](./RELAY_SETUP.md).
- An agent host that connects to an existing relay imports `nixosModules.buzz-acp` and follows [HEADLESS_AGENT_SETUP.md](./HEADLESS_AGENT_SETUP.md). It does not need to run a relay.
- A host that needs both option sets can import `nixosModules.default`. Each service remains disabled until its own `enable` option is set.

## Add the flake

`YOUR-ORG` is a placeholder for the GitHub owner of this repository. Replace it after publishing the checkout, or use a local URL such as `path:../buzz-nix` while developing.

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  inputs.buzz-nix = {
    url = "github:YOUR-ORG/buzz-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ nixpkgs, buzz-nix, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit inputs; };
      modules = [
        buzz-nix.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

`nixosModules.default` imports the relay and ACP option sets. Consumers can instead import `nixosModules.buzz-relay-container` or `nixosModules.buzz-acp` individually. `nixosModules.buzz-relay` is the same typed relay module as the container alias; setting `services.buzz-relay.container.enable = false` runs the service bundle directly on its NixOS host. Direct-host mode owns the host's NixOS PostgreSQL service, so use container mode when PostgreSQL is already managed there.

The `specialArgs` binding makes `inputs` available to `configuration.nix`. The default overlay adds `buzz-cli`, `buzz-acp`, `buzz-relay`, `buzz-ferron`, and `buzz-minio` to `pkgs`:

```nix
nixpkgs.overlays = [ inputs.buzz-nix.overlays.default ];
environment.systemPackages = [ pkgs.buzz-cli ];
```

The Ferron and MinIO overlay names carry a `buzz-` prefix to avoid collisions with nixpkgs. Flake package outputs use the shorter `ferron` and `minio` names. Direct package references do not require the overlay:

```nix
environment.systemPackages = [
  inputs.buzz-nix.packages.${pkgs.system}.buzz-cli
];
```

## Develop

```console
nix flake check
nix build .#buzz-cli
nix build .#buzz-acp
nix build .#buzz-relay
nix build .#ferron
nix build .#minio
```

Refresh the CLI and ACP packages from the latest stable Buzz Desktop release with:

```console
./scripts/update-buzz-desktop
```

Run the updater from a checkout with Python 3.9 or newer, Nix with flakes enabled, and network access to GitHub, crates.io, and the configured Nix substituters. It accepts `GITHUB_TOKEN` or `GH_TOKEN` for authenticated GitHub API requests.

The CLI and ACP packages share one source revision and Cargo lock, so the updater computes their shared fixed-output hashes through the CLI derivation and then builds both packages independently. It restores `versions.json` after ordinary failures or an interrupt handled by Python; abrupt process or host termination can leave an intermediate file. Pass `--tag desktop-vX.Y.Z` to test a specific release.

Format Nix sources with `nix fmt`.
