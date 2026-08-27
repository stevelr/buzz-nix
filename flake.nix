# SPDX-FileCopyrightText: 2026 Steve Schoettler
#
# SPDX-License-Identifier: Apache-2.0

{
  description = "Nix packages and NixOS modules for Buzz relays and headless agents";

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
            ferron = pkgs.callPackage ./packages/ferron.nix { };
            minio = pkgs.callPackage ./packages/minio.nix { };
          in
          {
            inherit
              buzz-cli
              buzz-acp
              buzz-admin
              buzz-agent
              buzz-relay
              buzz-pair-relay
              compute-auth-tag
              ferron
              minio
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
                system.stateVersion = "26.06";
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
                services.buzz-acp = {
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
                services.buzz-acp = {
                  enable = true;
                  relayUrl = "wss://relay.example.test";
                  environmentFile = "/run/keys/buzz-agent.env";
                  claudeAcp.enable = true;
                };
              }
            ];
          };
          ferronConfig = pkgs.writeText "buzz-relay-ferron.conf" directRelay.config.services.buzz-relay.ferron.configText;
          registrationScript =
            codexAgent.config.systemd.services.buzz-acp-registration.serviceConfig.ExecStart;
        in
        {
          ferron-config =
            pkgs.runCommand "buzz-relay-ferron-config"
              {
                nativeBuildInputs = [ self.packages.${system}.ferron ];
              }
              ''
                ferron validate -c ${ferronConfig}
                touch "$out"
              '';

          module-evaluation =
            assert builtins.seq directRelay.config.system.build.toplevel.drvPath true;
            assert builtins.seq containerRelay.config.containers.buzz-relay.config.system.build.toplevel.drvPath
              true;
            assert builtins.seq codexAgent.config.system.build.toplevel.drvPath true;
            assert builtins.seq claudeAgent.config.system.build.toplevel.drvPath true;
            assert directRelay.config.systemd.services ? buzz-relay;
            assert directRelay.config.systemd.services ? ferron;
            assert containerRelay.config.containers ? buzz-relay;
            assert
              containerRelay.config.containers.buzz-relay.config.services.buzz-relay.container.enable == false;
            assert containerRelay.config.containers.buzz-relay.config.networking.nameservers == [ "1.1.1.1" ];
            assert !containerRelay.config.containers.buzz-relay.config.networking.useHostResolvConf;
            assert codexAgent.config.systemd.services ? buzz-acp;
            assert codexAgent.config.systemd.services ? buzz-acp-registration;
            assert builtins.elem "buzz-acp-registration.service"
              codexAgent.config.systemd.services.buzz-acp.requires;
            assert
              codexAgent.config.systemd.services.buzz-acp-registration.environment.BUZZ_RELAY_URL
              == "wss://relay.example.test";
            assert
              codexAgent.config.systemd.services.buzz-acp-registration.serviceConfig.EnvironmentFile
              == "/run/keys/buzz-agent.env";
            assert !(claudeAgent.config.systemd.services ? buzz-acp-registration);
            assert
              claudeAgent.config.systemd.services.buzz-acp.environment.BUZZ_ACP_AGENT_COMMAND
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
