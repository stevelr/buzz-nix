<!--
SPDX-FileCopyrightText: 2026 Steve Schoettler

SPDX-License-Identifier: Apache-2.0
-->

# Relay setup

The relay module assembles Buzz, PostgreSQL, Redis, MinIO, and the temporary device-pairing relay as native systemd services. Container mode places that system in a declarative NixOS systemd-nspawn container and bind-mounts its persistent state from the host.

## Public relay with Ferron and ACME

Point the relay hostname at the NixOS host, permit inbound TCP ports 80 and 443, choose an unused private veth subnet, and reserve five consecutive numeric user and group IDs. Ferron terminates client TLS; its default ACME HTTP-01 challenge requires port 80.

Inspect `ip route show` before choosing the veth addresses. Check the proposed IDs against every configured name service; for the defaults, the following command should print nothing:

```console
for id in $(seq 5500 5504); do getent passwd "$id"; getent group "$id"; done
```

Add the flake as shown in [the README](./README.md#add-the-flake), then define the relay host inside that `outputs` block:

```nix
nixosConfigurations.relay-host = nixpkgs.lib.nixosSystem {
  system = "x86_64-linux";
  modules = [
    buzz-nix.nixosModules.buzz-relay
    # The host configuration owns hardware settings, boot setup, and
    # system.stateVersion.
    ./configuration.nix
    ({ ... }: {
      services.buzz-relay = {
        enable = true;

        container = {
          enable = true;
          name = "buzz-relay";
          hostAddress = "10.231.136.1";
          localAddress = "10.231.136.2";
          nameservers = [ "1.1.1.1" ];

          # Default persistence folder on host.
          # All services create permission-scoped folders below this.
          hostDataDir = "/srv/buzz-relay";
        };

        baseUid = 5500;
        baseGid = 5500;

        ferron = {
          enable = true;
          domain = "buzz.example.com";
          tls = {
            enable = true;
            mode = "acme";
            acme.contact = "ops@example.com";
          };
        };
      };
    })
  ];
};
```

Container mode disables `networking.useHostResolvConf` so a host-local resolver address is not copied into the private network namespace. `container.nameservers` supplies the container's resolver list and defaults to `[ "1.1.1.1" ]`.

### Host routing and NAT

The container uses the host-side veth address as its default gateway. Enable IPv4 forwarding and source NAT for container egress. If one external host address should terminate directly at the container, add DNAT in both `prerouting` and `output`: `prerouting` handles traffic arriving from other machines, while `output` handles connections originating on the host itself.

```nix
boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

# sample host nftables firewall to forward HTTPS from `10.10.10.10` to ferron on relay container.
networking.nftables = {
  enable = true;
  tables."buzz-relay-nat" = {
    family = "ip";
    content = ''
      chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        ip daddr 10.10.10.10 tcp dport 443 dnat to 10.231.136.2:443
      }

      chain output {
        type nat hook output priority dstnat; policy accept;
        ip daddr 10.10.10.10 tcp dport 443 dnat to 10.231.136.2:443
      }

      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr 10.231.136.2 masquerade comment "buzz-relay egress"
      }
    '';
  };
};
```

Only container egress is masqueraded, preserving the original client address for Ferron. The container's default route through `10.231.136.1` returns DNATed connections through the host. Change the DNAT destination port if `services.buzz-relay.ferron.httpsPort` is not 443. On a host whose forward chain has a drop policy, also add rules to that existing chain allowing new traffic to the published container ports, established return traffic, and container egress. An `accept` rule in a separate base chain does not override a drop in another base chain.

Apply the host configuration, then inspect the container and its services:

```console
sudo nixos-rebuild switch --flake .#relay-host
sudo nixos-container status buzz-relay
sudo nixos-container run buzz-relay -- systemctl --failed
sudo nixos-container run buzz-relay -- systemctl status buzz-relay ferron
```

The five IDs belong to the relay, PostgreSQL, Redis, MinIO, and Ferron. They must be unused on the host because bind-mounted files retain numeric ownership. The module opens service ports in the container's NixOS firewall and programs host-to-container forwarding. It does not manage a cloud firewall or upstream router.

The default port forwards expose Ferron on host ports 80 and 443. HTTP-01 requires public port 80 to reach Ferron; if another service owns that port, it must proxy the challenge traffic to Ferron, or the deployment must use TLS-ALPN-01, manual certificates, or an external TLS terminator. When either public application port is non-default, set `container.hostPorts`, `relayUrl`, and `mediaBaseUrl` consistently so clients receive reachable URLs.

Ferron stores its ACME account and certificates below `ferron.dataDir`, which defaults to `${rootDataDir}/ferron`. The cache therefore survives container replacement with the rest of the bind-mounted data.

## HTTP or an external TLS terminator

Ferron can proxy WebSockets without TLS:

```nix
services.buzz-relay.ferron = {
  enable = true;
  domain = "buzz.internal.example";
  tls.enable = false;
};
```

Ferron disables its HTTPS listener in this mode. Use it only on a trusted private network or behind another TLS terminator because HTTP and WebSocket traffic is unencrypted. The pairing sidecar remains on loopback and Ferron exposes it only at `/pair`; all other paths go to the main relay.

To run without Ferron, leave `ferron.enable = false`. Container mode then forwards `container.hostPorts.relay` to the main relay port. Pairing is disabled by default because it needs a reverse proxy for path routing and TLS.

For a reverse proxy on the host, expose the pairing listener only on the container network and allow that port through the container firewall:

```nix
services.buzz-relay = {
  relayUrl = "wss://buzz.example.com";
  mediaBaseUrl = "https://buzz.example.com/media";

  pairing = {
    enable = true;
    listenAddress = "0.0.0.0";
    publicUrl = "wss://buzz.example.com/pair";
  };

  container.extraConfig.networking.firewall.allowedTCPPorts = [ 8003 ];
};
```

Route ordinary HTTP and WebSocket requests to the main relay and only `/pair` to port 8003 at the container's `localAddress`. Do not add a public host port forward for the pairing listener; the host proxy can reach it over the private veth network.

Disabling Ferron still creates the main relay forward on `container.hostPorts.relay`, port 8000 by default. Deny public ingress to that host port in the host and upstream firewall policy, or clients can bypass the external TLS proxy.

## Manual TLS

Manual mode reads an existing certificate chain and private key from paths inside the container:

```nix
services.buzz-relay.ferron = {
  enable = true;
  domain = "buzz.example.com";
  extraGroups = [ "buzz-tls" ];
  tls = {
    enable = true;
    mode = "manual";
    certificateFile = "/var/lib/buzz-relay/tls/fullchain.pem";
    privateKeyFile = "/var/lib/buzz-relay/tls/key.pem";
  };
};

services.buzz-relay.container.extraConfig = {
  users.groups.buzz-tls.gid = 5510;
};
```

Place the files beneath the host data directory at `tls/fullchain.pem` and `tls/key.pem`. The Ferron user must be able to traverse the directory and read both files. With the default ID range, Ferron uses `baseUid + 4` and `baseGid + 4`; an explicit supplementary group is often easier for externally renewed keys. Restart Ferron after replacing manual certificate files because it loads them when the configuration is applied.

The supplementary group ID is outside the five-ID service range, so verify that it is also unused on the host. Install the files with numeric group ownership preserved through the bind mount:

```shell
sudo install -d -m 0710 -o root -g 5510 /srv/buzz-relay/tls
sudo install -m 0640 -o root -g 5510 fullchain.pem /srv/buzz-relay/tls/fullchain.pem
sudo install -m 0640 -o root -g 5510 key.pem /srv/buzz-relay/tls/key.pem
```

## Persistent layout and service IDs

The container is ephemeral by default (container can be destroyed and recreated),
so the services need a persistent disk location.
Designate a host folder, `hostDataDir`, which is mounted into the
container as `rootDataDir`. All service persistent data is mapped to subfolders
under those directories, with service-specific permissions.

```text
/var/lib/buzz-relay/
├── ferron/          ACME state
├── git/             relay repositories
├── git-pack-cache/  immutable Git packs
├── minio/           object storage
├── postgresql/      database cluster
├── redis/           append-only and snapshot state
├── relay/           relay working directory
├── secrets/         generated service credentials
└── owner.env        generated owner private key
```

The service range begins at `baseUid` and `baseGid`: relay is offset 0, PostgreSQL 1, Redis 2, MinIO 3, and Ferron 4. Each individual UID and GID can override its derived value. Container mode defaults to `privateUsers = "no"` because UID remapping changes ownership semantics for the persistent bind mount.

If any service data path is moved outside `rootDataDir`, make sure it has a writable host bind mount, and include it in the backup plan.

## Identities and membership

On first start, `buzz-relay-secrets.service` generates database, Redis, S3 (minio), relay, and owner credentials. Non-empty scalar secrets are preserved. Each relay or owner keypair is one unit: if either half is missing or empty, the service regenerates both files and rotates that identity. The derived environment files are rewritten whenever the secrets service runs. The generated `owner.env` contains `BUZZ_PRIVATE_KEY` for the relay owner and should be handled as a secret.

An owner identity is automatically generated. If you want to make yourself the owner, replace the contents of secrets/owner-public-key with your public key and restart the container.

Generate a separate signing identity for each user or headless agent. The command prints a public key and a secret key:

```console
nix run .#buzz-admin -- generate-key
```

Store the secret key immediately in the user's secret manager or protected environment file. Register only the public key with the relay. `buzz-admin` uses the internal database and Redis credentials from `relay.env`; the public `RELAY_URL` selects the community seeded by the relay:

Use the helper script `relay-env` to set the environment context needed for privileged commands like `buzz-admin`.

```shell
sudo nixos-container root-login buzz-relay # enter the container as root
relay-env buzz-admin list-members
relay-env buzz-admin add-member --pubkey PUBLIC_KEY 
relay-env buzz-admin list-members
exit
```

Each ACP agent needs its own registered key. Give its secret key to the agent machine through a root-managed secret file, mounted into the agent space to keep it out of the nix store.

## Backups and recovery

Back up all secret keys. With the default layout, `container.hostDataDir` contains the database, object and Git data, generated identities, membership authority, and Ferron ACME state. The shell trap below restarts the container if `rsync` fails or is interrupted:

```console
(
  set -e
  sudo nixos-container stop buzz-relay
  trap 'sudo nixos-container start buzz-relay' EXIT
  sudo rsync -aHAX --numeric-ids /srv/buzz-relay/ /backup/buzz-relay/
)
```

For recovery, stop the container, restore every persistent mount with `rsync -aHAX --numeric-ids`, and keep the configured UID/GID range unchanged. Rebuild the host configuration, start the container, and validate `systemctl --failed`, the readiness endpoint, and a signed `buzz channels list` request before admitting normal traffic. The database, object and Git data, relay identity, membership authority, and TLS state form one recovery unit.

The backup command above is specific to container mode. Direct-host mode has no aggregate service unit: an offline snapshot requires stopping `ferron`, `buzz-pair-relay`, and `buzz-relay` before `postgresql`, `buzz-redis`, and `buzz-minio`, omitting optional units that are disabled. Restart the stateful services before the relay and proxy. Direct-host mode owns the host's singleton PostgreSQL service and forces its package, port, data directory, UID, and GID; do not combine it with an independently managed host PostgreSQL deployment.

## Diagnostics

The main relay exposes `/_liveness` and `/_readiness` through Ferron. Its dedicated health and metrics listeners stay inside the container by default.

```console
curl --fail https://buzz.example.com/_liveness
curl --fail https://buzz.example.com/_readiness
sudo nixos-container run buzz-relay -- systemctl status \
  buzz-relay-secrets postgresql buzz-redis buzz-minio buzz-relay ferron
sudo nixos-container run buzz-relay -- journalctl -u buzz-relay -u ferron -n 200
```

ACME HTTP-01 requires public DNS to resolve to the host and unmodified inbound access to port 80. A Ferron validation failure appears in `systemctl status ferron` before the server starts.

## FAQ

### Isn't minio deprecated/non-free/out-of-favor?

I tried using `garage` but there were compatibility problems so I had to revert to a pinned version of minio, which is what buzz uses in it's [compose.yml sample](https://github.com/block/buzz/blob/main/deploy/compose/compose.yml) (as of v0.5.5).
