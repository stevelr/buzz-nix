# SPDX-FileCopyrightText: 2026 Steve Schoettler
#
# SPDX-License-Identifier: Apache-2.0

{
  self,
  llm-agents,
}:
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
    optional
    optionalAttrs
    types
    ;
  cfg = config.services.buzz-acp;
  system = pkgs.stdenv.hostPlatform.system;
  effectiveAgentCommand =
    if cfg.codexAcp.enable then
      "${cfg.codexAcp.package}/bin/codex-acp"
    else if cfg.claudeAcp.enable then
      "${cfg.claudeAcp.package}/bin/claude-agent-acp"
    else
      cfg.agentCommand;
  effectiveAgentArgs =
    if cfg.codexAcp.enable then
      cfg.codexAcp.args
    else if cfg.claudeAcp.enable then
      cfg.claudeAcp.args
    else
      cfg.agentArgs;
  runtimePackages = [
    self.packages.${system}.buzz-cli
    self.packages.${system}.buzz-agent
  ]
  ++ optional cfg.codexAcp.enable cfg.codexAcp.package
  ++ optional cfg.claudeAcp.enable cfg.claudeAcp.package
  ++ cfg.extraPackages;
in
{
  options.services.buzz-acp = {
    enable = mkEnableOption "Buzz ACP headless agent";

    package = mkOption {
      type = types.package;
      default = self.packages.${system}.buzz-acp;
      defaultText = literalExpression "buzz-nix.packages.\${pkgs.system}.buzz-acp";
      description = "Buzz ACP harness package.";
    };

    relayUrl = mkOption {
      type = types.str;
      default = "ws://localhost:8000";
      description = "Buzz relay WebSocket URL.";
    };

    environmentFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/buzz-agent.env";
      description = "Root-managed environment file containing BUZZ_PRIVATE_KEY and other credentials.";
    };

    user = mkOption {
      type = types.str;
      default = "buzz-agent";
      description = "User running the ACP harness.";
    };

    group = mkOption {
      type = types.str;
      default = "buzz-agent";
      description = "Primary group of the ACP harness user.";
    };

    createUser = mkOption {
      type = types.bool;
      default = true;
      description = "Create a dedicated dynamic system user and group.";
    };

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/buzz-acp";
      description = "Working directory and home for the dedicated agent user.";
    };

    agentCommand = mkOption {
      type = types.str;
      default = "goose";
      description = "ACP-compatible agent command used when codexAcp is disabled.";
    };

    agentArgs = mkOption {
      type = types.str;
      default = "acp";
      description = "Comma-separated arguments for agentCommand.";
    };

    agentOwner = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Optional 64-character owner public key.";
    };

    respondTo = mkOption {
      type = types.enum [
        "owner-only"
        "allowlist"
        "anyone"
        "nobody"
      ];
      default = "owner-only";
      description = "Inbound author gate enforced by buzz-acp.";
    };

    respondToAllowlist = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Public keys allowed when respondTo is allowlist.";
    };

    agents = mkOption {
      type = types.ints.between 1 32;
      default = 1;
      description = "Number of parallel ACP agent subprocesses.";
    };

    codexAcp = {
      enable = mkEnableOption "the codex-acp adapter";
      package = mkOption {
        type = types.package;
        default = llm-agents.packages.${system}.codex-acp;
        defaultText = literalExpression "llm-agents.packages.\${pkgs.system}.codex-acp";
        description = "codex-acp package to install and launch.";
      };
      args = mkOption {
        type = types.str;
        default = "";
        description = "Comma-separated arguments passed to codex-acp.";
      };
    };

    claudeAcp = {
      enable = mkEnableOption "the claude-agent-acp adapter";
      package = mkOption {
        type = types.package;
        default = llm-agents.packages.${system}.claude-agent-acp;
        defaultText = literalExpression "llm-agents.packages.\${pkgs.system}.claude-agent-acp";
        description = "claude-agent-acp package to install and launch.";
      };
      args = mkOption {
        type = types.str;
        default = "";
        description = "Comma-separated arguments passed to claude-agent-acp.";
      };
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Additional packages placed on the service PATH.";
    };

    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Additional non-secret service environment variables.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "ws://" cfg.relayUrl || lib.hasPrefix "wss://" cfg.relayUrl;
        message = "services.buzz-acp.relayUrl must use ws:// or wss://";
      }
      {
        assertion = cfg.environmentFile != null;
        message = "services.buzz-acp.environmentFile must provide BUZZ_PRIVATE_KEY outside the Nix store";
      }
      {
        assertion = cfg.respondTo != "allowlist" || cfg.respondToAllowlist != [ ];
        message = "services.buzz-acp.respondToAllowlist must not be empty when respondTo is allowlist";
      }
      {
        assertion = !(cfg.codexAcp.enable && cfg.claudeAcp.enable);
        message = "services.buzz-acp.codexAcp and claudeAcp cannot both be enabled";
      }
    ];

    users.groups.${cfg.group} = mkIf cfg.createUser { };
    users.users.${cfg.user} = mkIf cfg.createUser {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.stateDir;
      createHome = true;
    };

    environment.systemPackages = runtimePackages;

    systemd.tmpfiles.rules = mkIf cfg.createUser [
      "d '${cfg.stateDir}' 0750 ${cfg.user} ${cfg.group} -"
    ];

    systemd.services.buzz-acp = {
      description = "Buzz ACP headless agent";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = runtimePackages;
      environment =
        cfg.extraEnvironment
        // {
          NO_BROWSER = "1";
          INITIAL_AGENT_MODE = "agent";
          BUZZ_RELAY_URL = cfg.relayUrl;
          BUZZ_ACP_AGENT_COMMAND = effectiveAgentCommand;
          BUZZ_ACP_AGENT_ARGS = effectiveAgentArgs;
          BUZZ_ACP_RESPOND_TO = cfg.respondTo;
          BUZZ_ACP_AGENTS = toString cfg.agents;
        }
        // optionalAttrs (cfg.agentOwner != null) {
          BUZZ_ACP_AGENT_OWNER = cfg.agentOwner;
        }
        // optionalAttrs (cfg.respondToAllowlist != [ ]) {
          BUZZ_ACP_RESPOND_TO_ALLOWLIST = lib.concatStringsSep "," cfg.respondToAllowlist;
        };
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        EnvironmentFile = cfg.environmentFile;
        ExecStart = "${cfg.package}/bin/buzz-acp";
        WorkingDirectory = cfg.stateDir;
        Restart = "always";
        RestartSec = 5;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ cfg.stateDir ];
      };
    };
  };
}
