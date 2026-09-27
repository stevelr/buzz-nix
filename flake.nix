# SPDX-FileCopyrightText: 2026 Steve Schoettler
#
# SPDX-License-Identifier: Apache-2.0
{
  description = "Nix packages and modules for Buzz relays and headless agents";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    llm-agents = {
      url = "github:numtide/llm-agents.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      llm-agents,
      ...
    }:
    let
      # The supported platform list is limited by:
      #  - platforms supported by blocks/buzz
      #  - nix modules depend on nix and systemd
      #  - ferron is linux-only (although other proxies could be used)
      #  - testing (AFAIK, limited to x86_64-linux and aarch64-linux)
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      mkPackages =
        pkgs:
        (
          let
            buzz-cli = pkgs.callPackage ./packages/buzz-cli.nix { };
            buzz-acp = pkgs.callPackage ./packages/buzz-acp.nix { };
            buzz-admin = pkgs.callPackage ./packages/buzz-admin.nix { };
            buzz-agent = pkgs.callPackage ./packages/buzz-agent.nix { };
            buzz-relay = pkgs.callPackage ./packages/buzz-relay.nix { };
            buzz-pair-relay = pkgs.callPackage ./packages/buzz-pair-relay.nix { };
            compute-auth-tag = pkgs.callPackage ./packages/compute-auth-tag.nix { };
            buzz-ferron = pkgs.callPackage ./packages/ferron.nix { };
            buzz-minio = pkgs.callPackage ./packages/minio.nix { };
          in
          {
            inherit
              buzz-cli
              buzz-acp
              buzz-admin
              buzz-agent
              buzz-relay
              buzz-pair-relay
              buzz-ferron
              compute-auth-tag
              buzz-minio
              ;
            default = buzz-cli;
          }
        );
    in
    {
      overlays.default = final: _prev: {
        buzz-acp = final.callPackage ./packages/buzz-acp.nix { };
        buzz-cli = final.callPackage ./packages/buzz-cli.nix { };
        buzz-admin = final.callPackage ./packages/buzz-admin.nix { };
        buzz-agent = final.callPackage ./packages/buzz-agent.nix { };
        buzz-relay = final.callPackage ./packages/buzz-relay.nix { };
        buzz-pair-relay = final.callPackage ./packages/buzz-pair-relay.nix { };
        buzz-compute-auth-tag = final.callPackage ./packages/compute-auth-tag.nix { };
        buzz-ferron = final.callPackage ./packages/ferron.nix { };
        buzz-minio = final.callPackage ./packages/minio.nix { };
      };

      packages = forAllSystems (system: mkPackages nixpkgs.legacyPackages.${system});

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);

      nixosModules = {
        buzz-relay = import ./modules/buzz-relay.nix { inherit self; };
        buzz-acp = import ./modules/buzz-acp.nix { inherit self llm-agents; };
      };

      devShells = forAllSystems (
        system:
        (
          let
            pkgs = nixpkgs.legacyPackages.${system};
          in
          {
            default = pkgs.mkShell {
              buildInputs = [
                pkgs.nak
                pkgs.python3 # for scripts/update-buzz-desktop
                pkgs.git
                self.packages.${system}.buzz-admin
              ];
            };
          }
        )
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          directRelay = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.buzz-relay
              {
                boot.isContainer = true;
                system.stateVersion = "26.05";
                services.buzz-relay = {
                  enable = true;
                  container.enable = false;
                  ferron = {
                    enable = true;
                    domain = "relay.example.test";
                    tls.enable = false;
                  };
                };
              }
            ];
          };
          # vm.overcommit_memory should be applied to host when relay container is enabled
          hostRelay = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.buzz-relay
              {
                system.stateVersion = "26.05";
                boot.loader.grub.enable = false;
                fileSystems."/" = {
                  device = "/dev/disk/by-label/nixos";
                  fsType = "ext4";
                };
                services.buzz-relay = {
                  enable = true;
                  ferron = {
                    enable = true;
                    domain = "relay.example.test";
                    tls.enable = false;
                  };
                };
              }
            ];
          };
          containerRelay = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.buzz-relay
              {
                boot.isContainer = true;
                system.stateVersion = "26.05";
                services.buzz-relay = {
                  enable = true;
                  container.enable = true;
                  ferron = {
                    enable = true;
                    domain = "relay.example.test";
                    tls.enable = true;
                  };
                };
              }
            ];
          };
          codexAgent = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.buzz-acp
              {
                boot.isContainer = true;
                system.stateVersion = "26.05";
                services.buzz-acp.codex = {
                  enable = true;
                  relayUrl = "wss://relay.example.test";
                  environmentFile = "/run/keys/buzz-agent.env";
                  codexAcp.enable = true;
                  registration = {
                    enable = true;
                    displayName = "Codex test agent";
                    about = "Module evaluation fixture";
                  };
                };
              }
            ];
          };
          claudeAgent = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.buzz-acp
              {
                boot.isContainer = true;
                system.stateVersion = "26.05";
                services.buzz-acp.claude = {
                  enable = true;
                  relayUrl = "wss://relay.example.test";
                  environmentFile = "/run/keys/buzz-agent.env";
                  claudeAcp.enable = true;
                };
              }
            ];
          };
          multiAgent = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.buzz-acp
              {
                boot.isContainer = true;
                system.stateVersion = "26.05";
                services.buzz-acp = {
                  default = {
                    enable = true;
                    relayUrl = "wss://shared.example.test";
                    environmentFile = "/run/keys/shared.env";
                    extraEnvironment = {
                      SHARED = "shared";
                      OVERRIDE = "shared";
                    };
                    extraPackages = [ pkgs.hello ];
                    registration = {
                      enable = true;
                      about = "Shared profile";
                    };
                  };
                  codex = {
                    codexAcp.enable = true;
                    environmentFile = "/run/keys/codex.env";
                    registration.displayName = "Codex";
                    extraEnvironment.OVERRIDE = "codex";
                  };
                  qwen = {
                    agentCommand = "qwen";
                    agentArgs = "--acp";
                    registration.enable = false;
                    registration.about = null;
                    extraPackages = [ ];
                    extraEnvironment.QWEN = "yes";
                  };
                  disabled.enable = false;
                };
              }
            ];
          };
          defaultsOnly = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.buzz-acp
              {
                services.buzz-acp.default.enable = true;
              }
            ];
          };
          invalidAgent =
            settings:
            nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.buzz-acp
                {
                  services.buzz-acp.bad = {
                    enable = true;
                    environmentFile = "/run/keys/agent.env";
                  }
                  // settings;
                }
              ];
            };
          rejects =
            settings:
            builtins.any (
              a: !a.assertion && nixpkgs.lib.hasPrefix "services.buzz-acp.bad." a.message
            ) (invalidAgent settings).config.assertions;
          ferronConfig = pkgs.writeText "buzz-relay-ferron.conf" directRelay.config.services.buzz-relay.ferron.configText;
          registrationScript =
            codexAgent.config.systemd.services.buzz-acp-codex-registration.serviceConfig.ExecStart;
        in
        {
          ferron-config =
            pkgs.runCommand "buzz-relay-ferron-config"
              {
                nativeBuildInputs = [ self.packages.${system}.buzz-ferron ];
              }
              ''
                ferron validate -c ${ferronConfig}
                touch "$out"
              '';

          acp-instances =
            let
              services = multiAgent.config.systemd.services;
              codex = services.buzz-acp-codex;
              qwen = services.buzz-acp-qwen;
              instances = multiAgent.config.services.buzz-acp;
            in
            assert builtins.seq multiAgent.config.system.build.toplevel.drvPath true;
            assert !(services ? buzz-acp-default);
            assert !(services ? buzz-acp-disabled);
            assert !(services ? buzz-acp-qwen-registration);
            assert !(defaultsOnly.config.systemd.services ? buzz-acp-default);
            assert codex.environment.BUZZ_RELAY_URL == "wss://shared.example.test";
            assert qwen.serviceConfig.EnvironmentFile == "/run/keys/shared.env";
            assert codex.serviceConfig.EnvironmentFile == "/run/keys/codex.env";
            assert codex.environment.SHARED == "shared";
            assert codex.environment.OVERRIDE == "codex";
            assert qwen.environment.OVERRIDE == "shared";
            assert qwen.environment.QWEN == "yes";
            assert qwen.environment.BUZZ_ACP_AGENT_COMMAND == "qwen";
            assert qwen.environment.BUZZ_ACP_AGENT_ARGS == "--acp";
            assert instances.codex.registration.about == "Shared profile";
            assert instances.qwen.registration.about == null;
            assert instances.qwen.extraPackages == [ ];
            assert instances.codex.extraPackages == [ pkgs.hello ];
            assert instances.codex.user != instances.qwen.user;
            assert instances.codex.stateDir != instances.qwen.stateDir;
            assert instances.codex.uid == null && instances.qwen.uid == null;
            assert codex.requires == [ "buzz-acp-codex-registration.service" ];
            assert services.buzz-acp-codex-registration.before == [ "buzz-acp-codex.service" ];
            assert services.buzz-acp-codex-registration.serviceConfig.EnvironmentFile == "/run/keys/codex.env";
            assert !rejects { };
            assert rejects { environmentFile = null; };
            assert rejects { environmentFile = "relative.env"; };
            assert rejects { relayUrl = "https://invalid.test"; };
            assert rejects {
              codexAcp.enable = true;
              claudeAcp.enable = true;
            };
            pkgs.runCommand "buzz-acp-instances" { } "touch $out";

          module-evaluation =
            assert builtins.seq directRelay.config.system.build.toplevel.drvPath true;
            assert builtins.seq containerRelay.config.containers.buzz-relay.config.system.build.toplevel.drvPath
              true;
            assert builtins.seq codexAgent.config.system.build.toplevel.drvPath true;
            assert builtins.seq claudeAgent.config.system.build.toplevel.drvPath true;
            assert builtins.seq hostRelay.config.system.build.toplevel.drvPath true;
            assert directRelay.config.systemd.services ? buzz-relay;
            assert directRelay.config.systemd.services ? ferron;
            assert containerRelay.config.containers ? buzz-relay;
            assert
              containerRelay.config.containers.buzz-relay.config.services.buzz-relay.container.enable == false;
            assert
              builtins.length containerRelay.config.containers.buzz-relay.config.networking.nameservers > 0;
            assert !containerRelay.config.containers.buzz-relay.config.networking.useHostResolvConf;
            assert hostRelay.config.boot.kernel.sysctl."vm.overcommit_memory" == 1;
            assert hostRelay.config.containers.buzz-relay.config.boot.isContainer;
            assert !(hostRelay.config.containers.buzz-relay.config.boot.kernel.sysctl ? "vm.overcommit_memory");
            assert !(directRelay.config.boot.kernel.sysctl ? "vm.overcommit_memory");
            assert !(containerRelay.config.boot.kernel.sysctl ? "vm.overcommit_memory");
            assert codexAgent.config.systemd.services ? buzz-acp-codex;
            assert codexAgent.config.systemd.services ? buzz-acp-codex-registration;
            assert builtins.elem "buzz-acp-codex-registration.service"
              codexAgent.config.systemd.services.buzz-acp-codex.requires;
            assert
              codexAgent.config.systemd.services.buzz-acp-codex-registration.environment.BUZZ_RELAY_URL
              == "wss://relay.example.test";
            assert
              codexAgent.config.systemd.services.buzz-acp-codex-registration.serviceConfig.EnvironmentFile
              == "/run/keys/buzz-agent.env";
            assert !(claudeAgent.config.systemd.services ? buzz-acp-claude-registration);
            assert
              claudeAgent.config.systemd.services.buzz-acp-claude.environment.BUZZ_ACP_AGENT_COMMAND
              == "${llm-agents.packages.${system}.claude-agent-acp}/bin/claude-agent-acp";
            pkgs.runCommand "buzz-nixos-module-evaluation" { } ''
              grep -F 'BUZZ_AUTH_TAG' ${registrationScript}
              grep -F 'users set-profile' ${registrationScript}
              grep -F 'channels set-add-policy' ${registrationScript}
              touch "$out"
            '';
        }
      );
    };
}
