{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    literalExpression
    mkEnableOption
    mkIf
    mkOption
    types
    ;
  cfg = config.services.ferron;
  idType = types.ints.between 1 65535;
  configFile = pkgs.writeText "ferron.conf" cfg.configText;
in
{
  options.services.ferron = {
    enable = mkEnableOption "Ferron web server";

    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.ferron;
      defaultText = literalExpression "buzz-nix.packages.\${pkgs.system}.ferron";
      description = "Ferron package to run.";
    };

    configText = mkOption {
      type = types.lines;
      default = "";
      description = "Ferron configuration in ferronconf syntax.";
    };

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/ferron";
      description = "Writable Ferron state directory.";
    };

    user = mkOption {
      type = types.str;
      default = "ferron";
      description = "System user running Ferron.";
    };

    group = mkOption {
      type = types.str;
      default = "ferron";
      description = "Primary group of the Ferron user.";
    };

    uid = mkOption {
      type = idType;
      default = 5577;
      description = "Numeric UID of the Ferron user.";
    };

    gid = mkOption {
      type = idType;
      default = 5577;
      description = "Numeric GID of the Ferron group.";
    };

    extraGroups = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Supplementary groups used to grant access to TLS key material.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.configText != "";
        message = "services.ferron.configText must not be empty";
      }
      {
        assertion = lib.hasPrefix "/" cfg.dataDir;
        message = "services.ferron.dataDir must be absolute";
      }
    ];

    users.groups.${cfg.group}.gid = cfg.gid;
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      uid = cfg.uid;
      home = cfg.dataDir;
      extraGroups = cfg.extraGroups;
    };

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0750 ${cfg.user} ${cfg.group} -"
    ];

    environment.systemPackages = [ cfg.package ];

    systemd.services.ferron = {
      description = "Ferron web server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        ExecStartPre = "${cfg.package}/bin/ferron validate -c ${configFile}";
        ExecStart = "${cfg.package}/bin/ferron run -c ${configFile}";
        WorkingDirectory = cfg.dataDir;
        Restart = "on-failure";
        RestartSec = 5;
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ cfg.dataDir ];
      };
    };
  };
}
