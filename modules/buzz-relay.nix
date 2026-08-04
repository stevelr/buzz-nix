# SPDX-FileCopyrightText: 2026 Steve Schoettler
#
# SPDX-License-Identifier: Apache-2.0

{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    concatStringsSep
    escapeShellArg
    literalExpression
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    optional
    optionalAttrs
    optionals
    types
    ;

  cfg = config.services.buzz-relay;
  idType = types.ints.between 1 65535;
  baseIdType = types.ints.between 1 65531;

  relayEnvironmentFile = "${cfg.secretsDir}/relay.env";
  redisPasswordFile = "${cfg.secretsDir}/redis-password";
  postgresPasswordFile = "${cfg.secretsDir}/postgres-password";
  s3AccessKeyFile = "${cfg.secretsDir}/s3-access-key";
  s3SecretKeyFile = "${cfg.secretsDir}/s3-secret-key";
  minioEnvironmentFile = "${cfg.secretsDir}/minio.env";

  quoteFerron = value: ''"${lib.replaceStrings [ "\\" "\"" ] [ "\\\\" "\\\"" ] value}"'';
  ferronTls =
    if !cfg.ferron.tls.enable then
      "tls false"
    else if cfg.ferron.tls.mode == "manual" then
      ''
        tls {
            provider manual
            cert ${quoteFerron cfg.ferron.tls.certificateFile}
            key ${quoteFerron cfg.ferron.tls.privateKeyFile}
        }
      ''
    else
      ''
        tls {
            provider acme
            challenge ${cfg.ferron.tls.acme.challenge}
            cache ${quoteFerron "${cfg.ferron.dataDir}/acme"}
            ${lib.optionalString (
              cfg.ferron.tls.acme.contact != null
            ) "contact ${quoteFerron cfg.ferron.tls.acme.contact}"}
            ${lib.optionalString (
              cfg.ferron.tls.acme.directory != null
            ) "directory ${quoteFerron cfg.ferron.tls.acme.directory}"}
        }
      '';

  ferronConfigFile = pkgs.writeText "ferron.conf" cfg.ferron.configText;
  ferronNeedsBindCapability =
    cfg.ferron.httpPort < 1024 || (cfg.ferron.tls.enable && cfg.ferron.httpsPort < 1024);

  redisRuntimeConfig = pkgs.writeShellScript "buzz-redis-config" ''
    set -euo pipefail
    password="$(<${escapeShellArg redisPasswordFile})"
    umask 077
    {
      printf 'bind %s\n' ${escapeShellArg cfg.redis.listenAddress}
      printf 'port %s\n' ${escapeShellArg (toString cfg.redis.port)}
      printf 'protected-mode yes\n'
      printf 'daemonize no\n'
      printf 'supervised systemd\n'
      printf 'dir %s\n' ${escapeShellArg cfg.redis.dataDir}
      printf 'dbfilename dump.rdb\n'
      printf 'appendonly yes\n'
      printf 'appendfsync everysec\n'
      printf 'requirepass %s\n' "$password"
    } > /run/buzz-redis/redis.conf
  '';

  serviceValues = removeAttrs cfg [ "container" ];
  defaultForwards =
    if cfg.ferron.enable then
      [
        {
          protocol = "tcp";
          hostPort = cfg.container.hostPorts.http;
          containerPort = cfg.ferron.httpPort;
        }
      ]
      ++ optional cfg.ferron.tls.enable {
        protocol = "tcp";
        hostPort = cfg.container.hostPorts.https;
        containerPort = cfg.ferron.httpsPort;
      }
    else
      [
        {
          protocol = "tcp";
          hostPort = cfg.container.hostPorts.relay;
          containerPort = cfg.port;
        }
      ];
in
{
  options.services.buzz-relay = {
    enable = mkEnableOption "Buzz relay";

    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.buzz-relay;
      defaultText = literalExpression "buzz-nix.packages.\${pkgs.system}.buzz-relay";
      description = "Package containing buzz-relay, buzz-admin, and buzz-pair-relay.";
    };

    rootDataDir = mkOption {
      type = types.str;
      default = "/var/lib/buzz-relay";
      description = "Root of all persistent Buzz relay state.";
    };

    baseUid = mkOption {
      type = baseIdType;
      default = 5500;
      description = "First UID in the five-account relay service range.";
    };

    baseGid = mkOption {
      type = baseIdType;
      default = cfg.baseUid;
      defaultText = literalExpression "config.services.buzz-relay.baseUid";
      description = "First GID in the five-group relay service range.";
    };

    relayUrl = mkOption {
      type = types.str;
      default =
        if cfg.ferron.enable then
          "${if cfg.ferron.tls.enable then "wss" else "ws"}://${cfg.ferron.domain}"
        else
          "ws://localhost:${toString cfg.port}";
      defaultText = literalExpression "derived from ferron settings, or the relay port";
      description = "Public WebSocket URL advertised by the relay.";
    };

    mediaBaseUrl = mkOption {
      type = types.str;
      default =
        if cfg.ferron.enable then
          "${if cfg.ferron.tls.enable then "https" else "http"}://${cfg.ferron.domain}/media"
        else
          "http://localhost:${toString cfg.port}/media";
      defaultText = literalExpression "derived from ferron settings, or the relay port";
      description = "Public media URL ending in /media.";
    };

    corsOrigins = mkOption {
      type = types.listOf types.str;
      default = [ (lib.removeSuffix "/media" cfg.mediaBaseUrl) ];
      defaultText = literalExpression ''[ (lib.removeSuffix "/media" config.services.buzz-relay.mediaBaseUrl) ]'';
      description = "Origins allowed to call the relay HTTP API.";
    };

    listenAddress = mkOption {
      type = types.str;
      default = if cfg.ferron.enable then "127.0.0.1" else "0.0.0.0";
      defaultText = literalExpression ''if ferron.enable then "127.0.0.1" else "0.0.0.0"'';
      description = "Address on which the main relay listens.";
    };

    port = mkOption {
      type = types.port;
      default = 8000;
      description = "Relay HTTP and WebSocket port.";
    };

    healthPort = mkOption {
      type = types.port;
      default = 8001;
      description = "Relay liveness and readiness port.";
    };

    metricsPort = mkOption {
      type = types.port;
      default = 8002;
      description = "Relay Prometheus metrics port.";
    };

    relayDataDir = mkOption {
      type = types.str;
      default = "${cfg.rootDataDir}/relay";
      defaultText = literalExpression "\"\${config.services.buzz-relay.rootDataDir}/relay\"";
      description = "Relay working directory.";
    };

    secretsDir = mkOption {
      type = types.str;
      default = "${cfg.rootDataDir}/secrets";
      defaultText = literalExpression "\"\${config.services.buzz-relay.rootDataDir}/secrets\"";
      description = "Directory containing generated service credentials.";
    };

    ownerEnvironmentFile = mkOption {
      type = types.str;
      default = "${cfg.rootDataDir}/owner.env";
      defaultText = literalExpression "\"\${config.services.buzz-relay.rootDataDir}/owner.env\"";
      description = "Generated environment file containing the owner private key.";
    };

    ownerEnvironmentGroup = mkOption {
      type = types.str;
      default = "root";
      description = "Group allowed to read ownerEnvironmentFile.";
    };

    gitRepoDir = mkOption {
      type = types.str;
      default = "${cfg.rootDataDir}/git";
      defaultText = literalExpression "\"\${config.services.buzz-relay.rootDataDir}/git\"";
      description = "Directory for relay Git repositories.";
    };

    gitPackCacheDir = mkOption {
      type = types.str;
      default = "${cfg.rootDataDir}/git-pack-cache";
      defaultText = literalExpression "\"\${config.services.buzz-relay.rootDataDir}/git-pack-cache\"";
      description = "Directory for immutable Git pack cache data.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open the public relay or Ferron ports in the system firewall.";
    };

    user = {
      name = mkOption {
        type = types.str;
        default = "buzz-relay";
        description = "System user running the relay.";
      };
      group = mkOption {
        type = types.str;
        default = "buzz-relay";
        description = "Primary group of the relay user.";
      };
      uid = mkOption {
        type = idType;
        default = cfg.baseUid;
        defaultText = literalExpression "config.services.buzz-relay.baseUid";
        description = "Relay service UID.";
      };
      gid = mkOption {
        type = idType;
        default = cfg.baseGid;
        defaultText = literalExpression "config.services.buzz-relay.baseGid";
        description = "Relay service GID.";
      };
    };

    postgres = {
      package = mkOption {
        type = types.package;
        default = pkgs.postgresql_17;
        defaultText = literalExpression "pkgs.postgresql_17";
        description = "PostgreSQL package used by the relay.";
      };
      dataDir = mkOption {
        type = types.str;
        default = "${cfg.rootDataDir}/postgresql";
        defaultText = literalExpression "\"\${config.services.buzz-relay.rootDataDir}/postgresql\"";
        description = "PostgreSQL cluster directory.";
      };
      database = mkOption {
        type = types.str;
        default = "buzz";
        description = "PostgreSQL database used by the relay.";
      };
      role = mkOption {
        type = types.str;
        default = "buzz";
        description = "PostgreSQL login role used by the relay.";
      };
      port = mkOption {
        type = types.port;
        default = 5432;
        description = "Loopback PostgreSQL port.";
      };
      uid = mkOption {
        type = idType;
        default = cfg.baseUid + 1;
        defaultText = literalExpression "config.services.buzz-relay.baseUid + 1";
        description = "PostgreSQL service UID.";
      };
      gid = mkOption {
        type = idType;
        default = cfg.baseGid + 1;
        defaultText = literalExpression "config.services.buzz-relay.baseGid + 1";
        description = "PostgreSQL service GID.";
      };
    };

    redis = {
      package = mkOption {
        type = types.package;
        default = pkgs.redis;
        defaultText = literalExpression "pkgs.redis";
        description = "Redis package used by the relay.";
      };
      dataDir = mkOption {
        type = types.str;
        default = "${cfg.rootDataDir}/redis";
        defaultText = literalExpression "\"\${config.services.buzz-relay.rootDataDir}/redis\"";
        description = "Redis RDB and append-only state directory.";
      };
      listenAddress = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Address on which Redis listens.";
      };
      port = mkOption {
        type = types.port;
        default = 6379;
        description = "Redis port used by the relay.";
      };
      user = mkOption {
        type = types.str;
        default = "buzz-relay-redis";
        description = "Redis service user.";
      };
      group = mkOption {
        type = types.str;
        default = "buzz-relay-redis";
        description = "Redis service group.";
      };
      uid = mkOption {
        type = idType;
        default = cfg.baseUid + 2;
        defaultText = literalExpression "config.services.buzz-relay.baseUid + 2";
        description = "Redis service UID.";
      };
      gid = mkOption {
        type = idType;
        default = cfg.baseGid + 2;
        defaultText = literalExpression "config.services.buzz-relay.baseGid + 2";
        description = "Redis service GID.";
      };
    };

    minio = {
      package = mkOption {
        type = types.package;
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.minio;
        defaultText = literalExpression "buzz-nix.packages.\${pkgs.system}.minio";
        description = "MinIO server package pinned for Buzz.";
      };
      clientPackage = mkOption {
        type = types.package;
        default = pkgs.minio-client;
        defaultText = literalExpression "pkgs.minio-client";
        description = "MinIO client used to provision the Buzz bucket.";
      };
      dataDir = mkOption {
        type = types.str;
        default = "${cfg.rootDataDir}/minio";
        defaultText = literalExpression "\"\${config.services.buzz-relay.rootDataDir}/minio\"";
        description = "MinIO state directory.";
      };
      objectDataDir = mkOption {
        type = types.str;
        default = "${cfg.minio.dataDir}/data";
        defaultText = literalExpression "\"\${config.services.buzz-relay.minio.dataDir}/data\"";
        description = "MinIO object data directory.";
      };
      listenAddress = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Address on which MinIO exposes its S3 API.";
      };
      port = mkOption {
        type = types.port;
        default = 9000;
        description = "MinIO S3 API port.";
      };
      consoleAddress = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Address on which MinIO exposes its console.";
      };
      consolePort = mkOption {
        type = types.port;
        default = 9001;
        description = "MinIO console port.";
      };
      region = mkOption {
        type = types.str;
        default = "us-east-1";
        description = "S3 signing region exposed by MinIO.";
      };
      bucket = mkOption {
        type = types.str;
        default = "buzz-media";
        description = "Private MinIO bucket used by Buzz.";
      };
      user = mkOption {
        type = types.str;
        default = "buzz-relay-minio";
        description = "MinIO service user.";
      };
      group = mkOption {
        type = types.str;
        default = "buzz-relay-minio";
        description = "MinIO service group.";
      };
      uid = mkOption {
        type = idType;
        default = cfg.baseUid + 3;
        defaultText = literalExpression "config.services.buzz-relay.baseUid + 3";
        description = "MinIO service UID.";
      };
      gid = mkOption {
        type = idType;
        default = cfg.baseGid + 3;
        defaultText = literalExpression "config.services.buzz-relay.baseGid + 3";
        description = "MinIO service GID.";
      };
    };

    pairing = {
      enable = mkOption {
        type = types.bool;
        default = cfg.ferron.enable;
        defaultText = literalExpression "config.services.buzz-relay.ferron.enable";
        description = "Run the ephemeral pairing sidecar. It must be protected by a reverse proxy.";
      };
      listenAddress = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Loopback address on which the pairing sidecar listens.";
      };
      port = mkOption {
        type = types.port;
        default = 8003;
        description = "Pairing sidecar port.";
      };
      publicUrl = mkOption {
        type = types.nullOr types.str;
        default = if cfg.pairing.enable then "${cfg.relayUrl}/pair" else null;
        defaultText = literalExpression "if pairing.enable then \"\${relayUrl}/pair\" else null";
        description = "Public pairing WebSocket URL advertised through NIP-11.";
      };
    };

    ferron = {
      enable = mkEnableOption "Ferron reverse proxy for the Buzz relay";
      package = mkOption {
        type = types.package;
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.ferron;
        defaultText = literalExpression "buzz-nix.packages.\${pkgs.system}.ferron";
        description = "Ferron package to run.";
      };
      domain = mkOption {
        type = types.str;
        default = "localhost";
        description = "Ferron virtual host and public relay hostname.";
      };
      listenAddress = mkOption {
        type = types.str;
        default = "0.0.0.0";
        description = "Address on which Ferron listens.";
      };
      httpPort = mkOption {
        type = types.port;
        default = 80;
        description = "Ferron HTTP port.";
      };
      httpsPort = mkOption {
        type = types.port;
        default = 443;
        description = "Ferron HTTPS port.";
      };
      dataDir = mkOption {
        type = types.str;
        default = "${cfg.rootDataDir}/ferron";
        defaultText = literalExpression "\"\${config.services.buzz-relay.rootDataDir}/ferron\"";
        description = "Ferron state and ACME cache directory.";
      };
      user = mkOption {
        type = types.str;
        default = "buzz-relay-ferron";
        description = "Ferron service user.";
      };
      group = mkOption {
        type = types.str;
        default = "buzz-relay-ferron";
        description = "Ferron service group.";
      };
      uid = mkOption {
        type = idType;
        default = cfg.baseUid + 4;
        defaultText = literalExpression "config.services.buzz-relay.baseUid + 4";
        description = "Ferron service UID.";
      };
      gid = mkOption {
        type = idType;
        default = cfg.baseGid + 4;
        defaultText = literalExpression "config.services.buzz-relay.baseGid + 4";
        description = "Ferron service GID.";
      };
      extraGroups = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Supplementary groups used to read manual TLS key material.";
      };
      extraConfig = mkOption {
        type = types.lines;
        default = "";
        description = "Additional directives appended to the Ferron host block.";
      };
      tls = {
        enable = mkEnableOption "TLS termination in Ferron";
        mode = mkOption {
          type = types.enum [
            "acme"
            "manual"
          ];
          default = "acme";
          description = "Certificate provider used by Ferron.";
        };
        certificateFile = mkOption {
          type = types.str;
          default = "";
          description = "Certificate chain path for manual TLS.";
        };
        privateKeyFile = mkOption {
          type = types.str;
          default = "";
          description = "Private key path for manual TLS.";
        };
        acme = {
          contact = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "ACME account contact email.";
          };
          challenge = mkOption {
            type = types.enum [
              "http-01"
              "tls-alpn-01"
            ];
            default = "http-01";
            description = "ACME challenge type.";
          };
          directory = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Optional non-default ACME directory URL.";
          };
        };
      };
      configText = mkOption {
        type = types.str;
        default = ''
          {
              default_http_port ${toString cfg.ferron.httpPort}
              default_https_port ${if cfg.ferron.tls.enable then toString cfg.ferron.httpsPort else "false"}
              tcp {
                  listen ${quoteFerron cfg.ferron.listenAddress}
              }
          }

          ${cfg.ferron.domain} {
              ${ferronTls}
              ${lib.optionalString cfg.pairing.enable ''
                location /pair {
                    proxy http://${cfg.pairing.listenAddress}:${toString cfg.pairing.port}
                }
              ''}
              proxy http://${cfg.listenAddress}:${toString cfg.port}
              ${cfg.ferron.extraConfig}
          }
        '';
        description = "generated ferron configuration";
      };
    };

    container = {
      enable = mkEnableOption "a NixOS systemd-nspawn container for the relay";
      name = mkOption {
        type = types.str;
        default = "buzz-relay";
        description = "NixOS container name.";
      };
      autoStart = mkOption {
        type = types.bool;
        default = true;
        description = "Start the relay container during host boot.";
      };
      hostDataDir = mkOption {
        type = types.str;
        default = cfg.rootDataDir;
        defaultText = literalExpression "config.services.buzz-relay.rootDataDir";
        description = "Host directory bind-mounted at rootDataDir in the container.";
      };
      ephemeral = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to make the container ephemeral";
      };
      privateNetwork = mkOption {
        type = types.bool;
        default = true;
        description = "Give the container a private veth network.";
      };
      hostAddress = mkOption {
        type = types.nullOr types.str;
        default = "10.231.136.1";
        description = "Host-side address of the container veth pair (leave null if using hostBridge).";
      };
      hostBridge = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Name of host bridge (leave blank if using hostAddress).";
      };
      localAddress = mkOption {
        type = types.nullOr types.str;
        default = "10.231.136.2";
        description = "Container-side address of the veth pair.";
      };
      nameservers = mkOption {
        type = types.listOf types.str;
        default = [ "1.1.1.1" ];
        description = "DNS nameservers written to the container's resolv.conf.";
      };
      privateUsers = mkOption {
        type = types.either types.ints.u32 (
          types.enum [
            "no"
            "identity"
            "pick"
          ]
        );
        default = "no";
        description = "systemd-nspawn user namespace mode. Fixed service IDs and host bind mounts assume no remapping.";
      };
      hostPorts = {
        relay = mkOption {
          type = types.port;
          default = cfg.port;
          defaultText = literalExpression "config.services.buzz-relay.port";
          description = "Host port forwarded to the relay when Ferron is disabled.";
        };
        http = mkOption {
          type = types.port;
          default = cfg.ferron.httpPort;
          defaultText = literalExpression "config.services.buzz-relay.ferron.httpPort";
          description = "Host port forwarded to Ferron HTTP.";
        };
        https = mkOption {
          type = types.port;
          default = cfg.ferron.httpsPort;
          defaultText = literalExpression "config.services.buzz-relay.ferron.httpsPort";
          description = "Host port forwarded to Ferron HTTPS.";
        };
      };
      extraForwardPorts = mkOption {
        type = types.listOf (
          types.submodule {
            options = {
              protocol = mkOption {
                type = types.str;
                default = "tcp";
                description = "Forwarded protocol.";
              };
              hostPort = mkOption {
                type = types.port;
                description = "Port on the host.";
              };
              containerPort = mkOption {
                type = types.nullOr types.port;
                default = null;
                description = "Port in the container; defaults to hostPort.";
              };
            };
          }
        );
        default = [ ];
        description = "Additional host-to-container port forwards.";
      };
      extraBindMounts = mkOption {
        type = types.attrs;
        default = { };
        description = "Additional NixOS container bindMounts.";
      };
      extraConfig = mkOption {
        type = types.deferredModule;
        default = { };
        description = "Additional NixOS configuration evaluated inside the container.";
      };
    };

    autoMigrate = mkOption {
      type = types.bool;
      default = true;
      description = "Run embedded PostgreSQL migrations during relay startup.";
    };

    requireAuthToken = mkOption {
      type = types.bool;
      default = true;
      description = "Require authentication tokens for relay REST requests.";
    };

    requireRelayMembership = mkOption {
      type = types.bool;
      default = true;
      description = "Restrict authenticated callers to relay members.";
    };

    allowNipOaAuth = mkOption {
      type = types.bool;
      default = true;
      description = "Allow NIP-OA owner attestations for membership authentication.";
    };

    gitConformanceProbe = mkOption {
      type = types.bool;
      default = true;
      description = "Run the Git/S3 conformance probe during startup.";
    };

    logLevel = mkOption {
      type = types.str;
      default = "buzz_relay=info,buzz_db=info,buzz_auth=info,buzz_pubsub=info,tower_http=info";
      description = "RUST_LOG filter for the relay.";
    };

    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Additional non-secret environment variables for buzz-relay.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = lib.hasPrefix "ws://" cfg.relayUrl || lib.hasPrefix "wss://" cfg.relayUrl;
          message = "services.buzz-relay.relayUrl must use ws:// or wss://";
        }
        {
          assertion =
            (lib.hasPrefix "http://" cfg.mediaBaseUrl || lib.hasPrefix "https://" cfg.mediaBaseUrl)
            && lib.hasSuffix "/media" cfg.mediaBaseUrl;
          message = "services.buzz-relay.mediaBaseUrl must use http(s) and end in /media";
        }
        {
          assertion = lib.all (path: lib.hasPrefix "/" path) [
            cfg.rootDataDir
            cfg.relayDataDir
            cfg.secretsDir
            cfg.ownerEnvironmentFile
            cfg.gitRepoDir
            cfg.gitPackCacheDir
            cfg.postgres.dataDir
            cfg.redis.dataDir
            cfg.minio.dataDir
            cfg.minio.objectDataDir
            cfg.ferron.dataDir
          ];
          message = "all services.buzz-relay persistent paths must be absolute";
        }
        {
          assertion =
            builtins.length (
              lib.unique [
                cfg.relayDataDir
                cfg.postgres.dataDir
                cfg.redis.dataDir
                cfg.minio.dataDir
                cfg.ferron.dataDir
              ]
            ) == 5;
          message = "services.buzz-relay top-level service data directories must be distinct";
        }
        {
          assertion =
            builtins.length (
              lib.unique [
                cfg.user.uid
                cfg.postgres.uid
                cfg.redis.uid
                cfg.minio.uid
                cfg.ferron.uid
              ]
            ) == 5;
          message = "services.buzz-relay service UIDs must be distinct";
        }
        {
          assertion =
            builtins.length (
              lib.unique [
                cfg.user.gid
                cfg.postgres.gid
                cfg.redis.gid
                cfg.minio.gid
                cfg.ferron.gid
              ]
            ) == 5;
          message = "services.buzz-relay service GIDs must be distinct";
        }
        {
          assertion =
            builtins.length (
              lib.unique (
                [
                  cfg.port
                  cfg.healthPort
                  cfg.metricsPort
                  cfg.postgres.port
                  cfg.redis.port
                  cfg.minio.port
                  cfg.minio.consolePort
                ]
                ++ optional cfg.pairing.enable cfg.pairing.port
                ++ optionals cfg.ferron.enable (
                  [ cfg.ferron.httpPort ] ++ optional cfg.ferron.tls.enable cfg.ferron.httpsPort
                )
              )
            ) == 7
            + (if cfg.pairing.enable then 1 else 0)
            + (if cfg.ferron.enable then 1 else 0)
            + (if cfg.ferron.enable && cfg.ferron.tls.enable then 1 else 0);
          message = "services.buzz-relay service ports must be distinct";
        }

        {
          assertion = !(cfg.container.hostAddress != null && cfg.container.hostBridge != null);
          message = "Either use container.hostAddress or container.hostBridge, but not both. (They cannot both be non-null)";
        }
        {
          assertion = builtins.match "[A-Za-z_][A-Za-z0-9_]*" cfg.postgres.database != null;
          message = "services.buzz-relay.postgres.database must be a simple SQL identifier";
        }
        {
          assertion = builtins.match "[A-Za-z_][A-Za-z0-9_]*" cfg.postgres.role != null;
          message = "services.buzz-relay.postgres.role must be a simple SQL identifier";
        }
        {
          assertion = !cfg.ferron.enable || builtins.match "[A-Za-z0-9.*:_-]+" cfg.ferron.domain != null;
          message = "services.buzz-relay.ferron.domain contains unsupported characters";
        }
        {
          assertion =
            !cfg.ferron.tls.enable
            || cfg.ferron.tls.mode != "manual"
            || (
              lib.hasPrefix "/" cfg.ferron.tls.certificateFile && lib.hasPrefix "/" cfg.ferron.tls.privateKeyFile
            );
          message = "manual Ferron TLS requires absolute certificateFile and privateKeyFile paths";
        }
        {
          assertion = !cfg.pairing.enable || cfg.ferron.enable || cfg.pairing.publicUrl != null;
          message = "pairing requires Ferron or an explicit pairing.publicUrl behind another reverse proxy";
        }
      ];
    }

    (mkIf cfg.container.enable {
      systemd.tmpfiles.rules = [
        "d '${cfg.container.hostDataDir}' 0711 root root -"
      ];

      containers.${cfg.container.name} = {
        inherit (cfg.container)
          autoStart
          ephemeral
          hostAddress
          localAddress
          privateNetwork
          privateUsers
          ;
        forwardPorts = defaultForwards ++ cfg.container.extraForwardPorts;
        bindMounts = cfg.container.extraBindMounts // {
          ${cfg.rootDataDir} = {
            hostPath = cfg.container.hostDataDir;
            isReadOnly = false;
          };
        };
        config = {
          imports = [
            self.nixosModules.buzz-relay
            cfg.container.extraConfig
          ];
          nixpkgs.pkgs = pkgs;
          networking = {
            inherit (cfg.container) nameservers;
            useHostResolvConf = false;
          };
          services.buzz-relay = serviceValues // {
            container.enable = false;
          };
          system.stateVersion = "25.11";
        };
      };
    })

    (mkIf (!cfg.container.enable) {
      users.groups.${cfg.user.group}.gid = cfg.user.gid;
      users.users.${cfg.user.name} = {
        isSystemUser = true;
        group = cfg.user.group;
        uid = cfg.user.uid;
        home = cfg.relayDataDir;
      };

      users.groups.${cfg.redis.group}.gid = cfg.redis.gid;
      users.users.${cfg.redis.user} = {
        isSystemUser = true;
        group = cfg.redis.group;
        uid = cfg.redis.uid;
        home = cfg.redis.dataDir;
      };

      users.groups.${cfg.minio.group}.gid = cfg.minio.gid;
      users.users.${cfg.minio.user} = {
        isSystemUser = true;
        group = cfg.minio.group;
        uid = cfg.minio.uid;
        home = cfg.minio.dataDir;
      };

      users.groups.${cfg.ferron.group}.gid = cfg.ferron.gid;
      users.users.${cfg.ferron.user} = {
        isSystemUser = true;
        group = cfg.ferron.group;
        uid = cfg.ferron.uid;
        home = cfg.ferron.dataDir;
        extraGroups = cfg.ferron.extraGroups;
      };

      ids.uids.postgres = lib.mkForce cfg.postgres.uid;
      ids.gids.postgres = lib.mkForce cfg.postgres.gid;
      users.users.postgres.isSystemUser = true;

      services.postgresql = {
        enable = true;
        package = cfg.postgres.package;
        dataDir = cfg.postgres.dataDir;
        settings = {
          port = cfg.postgres.port;
        };
        ensureDatabases = [ cfg.postgres.database ];
        ensureUsers = [
          {
            name = cfg.postgres.role;
            ensureDBOwnership = false;
          }
        ];
      };

      environment.systemPackages = [
        cfg.package
        cfg.redis.package
        cfg.minio.package
        cfg.minio.clientPackage
        cfg.ferron.package
      ];

      networking.nftables.enable = true;
      networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall (
        if cfg.ferron.enable then
          [ cfg.ferron.httpPort ] ++ optional cfg.ferron.tls.enable cfg.ferron.httpsPort
        else
          [ cfg.port ]
      );

      systemd.tmpfiles.rules = [
        "d '${cfg.rootDataDir}' 0711 root root -"
        "d '${cfg.relayDataDir}' 0750 ${cfg.user.name} ${cfg.user.group} -"
        "d '${cfg.gitRepoDir}' 0750 ${cfg.user.name} ${cfg.user.group} -"
        "d '${cfg.gitPackCacheDir}' 0750 ${cfg.user.name} ${cfg.user.group} -"
        "d '${cfg.secretsDir}' 0711 root root -"
        "d '${cfg.redis.dataDir}' 0750 ${cfg.redis.user} ${cfg.redis.group} -"
        "d '${cfg.postgres.dataDir}' 0750 postgres postgres -"
        "d '${cfg.minio.dataDir}' 0750 ${cfg.minio.user} ${cfg.minio.group} -"
        "d '${cfg.minio.objectDataDir}' 0750 ${cfg.minio.user} ${cfg.minio.group} -"
        "d '${cfg.ferron.dataDir}' 0750 ${cfg.ferron.user} ${cfg.ferron.group} -"
      ];

      # needed for minio
      # Memory overcommit must be enabled! Without it, a background save or replication
      # may fail under low memory condition. Being disabled, it can also cause failures
      # see https://github.com/jemalloc/jemalloc/issues/1328.
      boot.kernel.sysctl."vm.overcommit_memory" = 1;

      systemd.services = {
        buzz-relay-secrets = {
          description = "Generate persistent Buzz relay credentials";
          wantedBy = [ "multi-user.target" ];
          before = [
            "postgresql.service"
            "buzz-redis.service"
            "buzz-minio.service"
            "buzz-relay.service"
          ];
          path = [
            pkgs.coreutils
            pkgs.gawk
            pkgs.openssl
            cfg.package
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            set -euo pipefail
            umask 077
            install -d -m 0711 -o root -g root ${escapeShellArg cfg.secretsDir}

            generate_secret() {
              local path="$1"
              local bytes="$2"
              if [[ ! -s "$path" ]]; then
                openssl rand -hex "$bytes" > "$path"
              fi
            }

            generate_keypair() {
              local prefix="$1"
              if [[ ! -s "${cfg.secretsDir}/$prefix-private-key" || ! -s "${cfg.secretsDir}/$prefix-public-key" ]]; then
                local output public private
                output="$(buzz-admin generate-key)"
                public="$(awk '$1 == "Public" && $2 == "key:" { print $3 }' <<<"$output")"
                private="$(awk '$1 == "Secret" && $2 == "key:" { print $3 }' <<<"$output")"
                [[ "$public" =~ ^[0-9a-f]{64}$ && "$private" =~ ^[0-9a-f]{64}$ ]]
                printf '%s\n' "$public" > "${cfg.secretsDir}/$prefix-public-key"
                printf '%s\n' "$private" > "${cfg.secretsDir}/$prefix-private-key"
              fi
            }

            generate_secret ${escapeShellArg postgresPasswordFile} 32
            generate_secret ${escapeShellArg redisPasswordFile} 32
            generate_secret ${escapeShellArg s3AccessKeyFile} 16
            generate_secret ${escapeShellArg s3SecretKeyFile} 32
            generate_secret ${escapeShellArg "${cfg.secretsDir}/git-hook-hmac-secret"} 32
            generate_keypair relay
            generate_keypair owner

            postgres_password="$(<${escapeShellArg postgresPasswordFile})"
            redis_password="$(<${escapeShellArg redisPasswordFile})"
            s3_access_key="$(<${escapeShellArg s3AccessKeyFile})"
            s3_secret_key="$(<${escapeShellArg s3SecretKeyFile})"
            relay_private_key="$(<${escapeShellArg "${cfg.secretsDir}/relay-private-key"})"
            owner_public_key="$(<${escapeShellArg "${cfg.secretsDir}/owner-public-key"})"
            owner_private_key="$(<${escapeShellArg "${cfg.secretsDir}/owner-private-key"})"
            git_hook_hmac_secret="$(<${escapeShellArg "${cfg.secretsDir}/git-hook-hmac-secret"})"

            relay_env="$(mktemp)"
            {
              printf 'DATABASE_URL=postgres://%s:%s@127.0.0.1:%s/%s\n' \
                ${escapeShellArg cfg.postgres.role} "$postgres_password" \
                ${escapeShellArg (toString cfg.postgres.port)} ${escapeShellArg cfg.postgres.database}
              printf 'REDIS_URL=redis://:%s@%s:%s\n' "$redis_password" \
                ${escapeShellArg cfg.redis.listenAddress} ${escapeShellArg (toString cfg.redis.port)}
              printf 'BUZZ_RELAY_PRIVATE_KEY=%s\n' "$relay_private_key"
              printf 'RELAY_OWNER_PUBKEY=%s\n' "$owner_public_key"
              printf 'BUZZ_GIT_HOOK_HMAC_SECRET=%s\n' "$git_hook_hmac_secret"
              printf 'BUZZ_S3_ACCESS_KEY=%s\n' "$s3_access_key"
              printf 'BUZZ_S3_SECRET_KEY=%s\n' "$s3_secret_key"
            } > "$relay_env"
            install -m 0640 -o root -g ${escapeShellArg cfg.user.group} \
              "$relay_env" ${escapeShellArg relayEnvironmentFile}
            rm -f "$relay_env"

            minio_env="$(mktemp)"
            {
              printf 'MINIO_ROOT_USER=%s\n' "$s3_access_key"
              printf 'MINIO_ROOT_PASSWORD=%s\n' "$s3_secret_key"
              printf 'MINIO_REGION_NAME=%s\n' ${escapeShellArg cfg.minio.region}
            } > "$minio_env"
            install -m 0640 -o root -g ${escapeShellArg cfg.minio.group} \
              "$minio_env" ${escapeShellArg minioEnvironmentFile}
            rm -f "$minio_env"

            owner_env="$(mktemp)"
            printf 'BUZZ_PRIVATE_KEY=%s\n' "$owner_private_key" > "$owner_env"
            install -Dm0640 -o root -g ${escapeShellArg cfg.ownerEnvironmentGroup} \
              "$owner_env" ${escapeShellArg cfg.ownerEnvironmentFile}
            rm -f "$owner_env"

            chown root:postgres ${escapeShellArg postgresPasswordFile}
            chmod 0640 ${escapeShellArg postgresPasswordFile}
            chown root:${escapeShellArg cfg.redis.group} ${escapeShellArg redisPasswordFile}
            chmod 0640 ${escapeShellArg redisPasswordFile}
          '';
        };

        postgresql = {
          requires = [ "buzz-relay-secrets.service" ];
          after = [ "buzz-relay-secrets.service" ];
          serviceConfig.ProtectHome = lib.mkForce (!lib.hasPrefix "/home/" cfg.postgres.dataDir);
        };

        buzz-redis = {
          description = "Buzz private Redis service";
          wantedBy = [ "multi-user.target" ];
          requires = [ "buzz-relay-secrets.service" ];
          after = [
            "network.target"
            "buzz-relay-secrets.service"
          ];
          serviceConfig = {
            Type = "notify";
            User = cfg.redis.user;
            Group = cfg.redis.group;
            RuntimeDirectory = "buzz-redis";
            RuntimeDirectoryMode = "0750";
            ExecStartPre = redisRuntimeConfig;
            ExecStart = "${cfg.redis.package}/bin/redis-server /run/buzz-redis/redis.conf";
            Restart = "on-failure";
            RestartSec = 5;
            NoNewPrivileges = true;
            PrivateDevices = true;
            PrivateTmp = true;
            ProtectHome = !lib.hasPrefix "/home/" cfg.redis.dataDir;
            ProtectSystem = "strict";
            ReadWritePaths = [ cfg.redis.dataDir ];
          };
        };

        buzz-minio = {
          description = "Buzz MinIO S3-compatible object storage";
          wantedBy = [ "multi-user.target" ];
          requires = [ "buzz-relay-secrets.service" ];
          after = [ "buzz-relay-secrets.service" ];
          serviceConfig = {
            Type = "simple";
            User = cfg.minio.user;
            Group = cfg.minio.group;
            EnvironmentFile = minioEnvironmentFile;
            ExecStart = concatStringsSep " " [
              "${cfg.minio.package}/bin/minio server"
              "--address ${escapeShellArg "${cfg.minio.listenAddress}:${toString cfg.minio.port}"}"
              "--console-address ${escapeShellArg "${cfg.minio.consoleAddress}:${toString cfg.minio.consolePort}"}"
              (escapeShellArg cfg.minio.objectDataDir)
            ];
            Restart = "on-failure";
            RestartSec = 5;
            LimitNOFILE = 42000;
            NoNewPrivileges = true;
            PrivateDevices = true;
            PrivateTmp = true;
            ProtectHome = !lib.hasPrefix "/home/" cfg.minio.dataDir;
            ProtectSystem = "strict";
            ReadWritePaths = [
              cfg.minio.dataDir
              cfg.minio.objectDataDir
            ];
          };
        };

        buzz-postgres-password = {
          description = "Set the Buzz PostgreSQL role password";
          requires = [
            "buzz-relay-secrets.service"
            "postgresql.service"
            "postgresql-setup.service"
          ];
          after = [
            "buzz-relay-secrets.service"
            "postgresql.service"
            "postgresql-setup.service"
          ];
          serviceConfig = {
            Type = "oneshot";
            User = "postgres";
            Group = "postgres";
          };
          script = ''
            set -euo pipefail
            password="$(<${escapeShellArg postgresPasswordFile})"
            ${cfg.postgres.package}/bin/psql \
              --dbname postgres \
              --port ${toString cfg.postgres.port} \
              --set ON_ERROR_STOP=1 \
              --command "ALTER ROLE ${cfg.postgres.role} PASSWORD '$password'" \
              --command "ALTER DATABASE ${cfg.postgres.database} OWNER TO ${cfg.postgres.role}"
          '';
        };

        buzz-minio-bootstrap = {
          description = "Create the private Buzz MinIO bucket";
          requires = [
            "buzz-relay-secrets.service"
            "buzz-minio.service"
          ];
          after = [
            "buzz-relay-secrets.service"
            "buzz-minio.service"
          ];
          path = [
            pkgs.coreutils
            pkgs.curl
            pkgs.getent
            cfg.minio.clientPackage
          ];
          serviceConfig = {
            Type = "oneshot";
            RuntimeDirectory = "buzz-minio-bootstrap";
            RuntimeDirectoryMode = "0700";
          };
          script = ''
            set -euo pipefail
            ready=
            for _ in $(seq 1 60); do
              if curl --fail --silent --show-error \
                ${escapeShellArg "http://${cfg.minio.listenAddress}:${toString cfg.minio.port}/minio/health/live"} \
                >/dev/null; then
                ready=1
                break
              fi
              sleep 1
            done
            [[ -n "$ready" ]]

            export MC_CONFIG_DIR=/run/buzz-minio-bootstrap
            s3_access_key="$(<${escapeShellArg s3AccessKeyFile})"
            s3_secret_key="$(<${escapeShellArg s3SecretKeyFile})"
            mc alias set local \
              ${escapeShellArg "http://${cfg.minio.listenAddress}:${toString cfg.minio.port}"} \
              "$s3_access_key" "$s3_secret_key"
            mc mb --ignore-existing ${escapeShellArg "local/${cfg.minio.bucket}"}
            mc anonymous set none ${escapeShellArg "local/${cfg.minio.bucket}"}
          '';
        };

        buzz-pair-relay = mkIf cfg.pairing.enable {
          description = "Buzz ephemeral device-pairing relay";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          environment.BUZZ_PAIR_RELAY_BIND_ADDR = "${cfg.pairing.listenAddress}:${toString cfg.pairing.port}";
          serviceConfig = {
            Type = "simple";
            User = cfg.user.name;
            Group = cfg.user.group;
            ExecStart = "${cfg.package}/bin/buzz-pair-relay";
            Restart = "on-failure";
            RestartSec = 5;
            NoNewPrivileges = true;
            PrivateDevices = true;
            PrivateTmp = true;
            ProtectHome = true;
            ProtectSystem = "strict";
          };
        };

        buzz-relay = {
          description = "Buzz WebSocket relay";
          wantedBy = [ "multi-user.target" ];
          requires = [
            "buzz-relay-secrets.service"
            "buzz-postgres-password.service"
            "buzz-redis.service"
            "buzz-minio-bootstrap.service"
          ];
          after = [
            "network-online.target"
            "buzz-relay-secrets.service"
            "buzz-postgres-password.service"
            "buzz-redis.service"
            "buzz-minio-bootstrap.service"
          ];
          wants = [ "network-online.target" ];
          path = [ pkgs.git ];
          environment =
            cfg.extraEnvironment
            // {
              BUZZ_BIND_ADDR = "${cfg.listenAddress}:${toString cfg.port}";
              BUZZ_HEALTH_PORT = toString cfg.healthPort;
              BUZZ_METRICS_PORT = toString cfg.metricsPort;
              BUZZ_S3_ENDPOINT = "http://${cfg.minio.listenAddress}:${toString cfg.minio.port}";
              BUZZ_S3_ADDRESSING_STYLE = "path";
              BUZZ_S3_BUCKET = cfg.minio.bucket;
              BUZZ_S3_REGION = cfg.minio.region;
              BUZZ_GIT_REPO_PATH = cfg.gitRepoDir;
              BUZZ_GIT_PACK_CACHE_PATH = cfg.gitPackCacheDir;
              BUZZ_AUTO_MIGRATE = lib.boolToString cfg.autoMigrate;
              BUZZ_GIT_CONFORMANCE_PROBE = lib.boolToString cfg.gitConformanceProbe;
              BUZZ_REQUIRE_AUTH_TOKEN = lib.boolToString cfg.requireAuthToken;
              BUZZ_REQUIRE_RELAY_MEMBERSHIP = lib.boolToString cfg.requireRelayMembership;
              BUZZ_ALLOW_NIP_OA_AUTH = lib.boolToString cfg.allowNipOaAuth;
              BUZZ_CORS_ORIGINS = concatStringsSep "," cfg.corsOrigins;
              BUZZ_MEDIA_BASE_URL = cfg.mediaBaseUrl;
              RELAY_URL = cfg.relayUrl;
              RUST_LOG = cfg.logLevel;
            }
            // optionalAttrs (cfg.pairing.publicUrl != null) {
              BUZZ_PAIRING_RELAY_URL = cfg.pairing.publicUrl;
            };
          serviceConfig = {
            Type = "simple";
            User = cfg.user.name;
            Group = cfg.user.group;
            EnvironmentFile = relayEnvironmentFile;
            ExecStart = "${cfg.package}/bin/buzz-relay";
            WorkingDirectory = cfg.relayDataDir;
            Restart = "on-failure";
            RestartSec = 5;
            NoNewPrivileges = true;
            PrivateDevices = true;
            PrivateTmp = true;
            ProtectHome = !lib.hasPrefix "/home/" cfg.rootDataDir;
            ProtectSystem = "strict";
            ReadWritePaths = [
              cfg.relayDataDir
              cfg.gitRepoDir
              cfg.gitPackCacheDir
            ];
          };
        };

        ferron = mkIf cfg.ferron.enable {
          description = "Ferron web server";
          after = [
            "network-online.target"
            "buzz-relay.service"
          ]
          ++ optional cfg.pairing.enable "buzz-pair-relay.service";
          requires = [
            "buzz-relay.service"
          ]
          ++ optional cfg.pairing.enable "buzz-pair-relay.service";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            Type = "simple";
            User = cfg.ferron.user;
            Group = cfg.ferron.group;
            ExecStartPre = "${cfg.ferron.package}/bin/ferron validate -c ${ferronConfigFile}";
            ExecStart = "${cfg.ferron.package}/bin/ferron run -c ${ferronConfigFile}";
            WorkingDirectory = cfg.ferron.dataDir;
            Restart = "on-failure";
            RestartSec = 5;
            AmbientCapabilities = optional ferronNeedsBindCapability "CAP_NET_BIND_SERVICE";
            CapabilityBoundingSet = optional ferronNeedsBindCapability "CAP_NET_BIND_SERVICE";
            NoNewPrivileges = true;
            PrivateDevices = true;
            PrivateTmp = true;
            ProtectHome = true;
            ProtectSystem = "strict";
            ReadWritePaths = [ cfg.ferron.dataDir ];
          };
        };
      };
    })
  ]);
}
