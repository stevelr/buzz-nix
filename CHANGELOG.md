<!--
SPDX-FileCopyrightText: 2026 Steve Schoettler

SPDX-License-Identifier: Apache-2.0
-->

# Changelog

## 1.0.0 (unreleased)

### Breaking changes

- `services.buzz-acp` accepts named instances. Move the previous single-agent
  configuration into an entry such as `services.buzz-acp.codex`.
- Harness units are named `buzz-acp-<name>.service`; registration units are
  named `buzz-acp-<name>-registration.service`. Update systemd overrides,
  monitoring, and operational commands to use these names.
- Each instance defaults to its own `buzz-agent-<name>` user and group, with
  NixOS-allocated IDs, and `/var/lib/buzz-acp-<name>` as its state directory.
  To preserve an existing installation, explicitly configure its previous
  account, numeric IDs, and state directory. See the
  [state migration instructions](./HEADLESS_AGENT_SETUP.md#multiple-instances-and-defaults).
- buzz-nix adopts independent semantic versions and `vMAJOR.MINOR.PATCH` tags,
  starting with `v1.0.0`. `VERSION` records the buzz-nix version; packaged Buzz
  versions remain recorded separately in `versions.json`.

### Added

- `services.buzz-acp.default` supplies shared options without creating a
  service. Named instances override shared values, including `false`, `null`,
  and lists; nested settings inherit omitted fields, and environment variables
  merge by name.
- Each enabled instance has its own harness and optional identity registration.
- Module checks cover multiple instances, shared defaults, overrides, disabled
  instances, registration dependencies, and invalid configurations.

## 0.5.25

- update to buzz-desktop 0.5.25

### Changes

**Breaking**:

- container.enable defaults to true to provide better reproducibility and isolation. (container also defaults to ephemeral) If you didn't enable this before and don't want the relay service to run in its own container, set to false.
- postgres uid/gid defaults to nix's default postgres uid/gid. To migrate, stop the relay container, then `sudo chown -R 71:71 /var/lib/buzz-relay/postgresql`
- container.nameservers changed from `["1.1.1.1"]` to `[ hostAddress ]`. If your host runs a dns server configured to listen on all interfaces, it will probably still work. Otherwise, set container.nameservers to an explicit list of dns servers.
- mountpoint defaults to attribute name

  Added:
  - added flake checks/assertions

  Fixed:
  - use correct package names buzz-ferron and buzz-minio to avoid potential conflicts;
  - set package defaults so consumer overlays and nixpkgs.apply.
  - nftables only set if in container mode (doesn't change firewall if in host mode)
  - several settings changed to mkDefault;
  - default set veth pair to unmanaged network to work around systemd bug that allocates additional 172.16 address;
  - declare option types for extraBindMounts (was untyped types.attrs)
  - fix boot.overcommit_memory setting to apply only on host
  - patch tests to use nixos-compatible shebang header

## 0.5.23

- update to buzz-desktop 0.5.25
