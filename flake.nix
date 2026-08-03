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
      mkPackages = pkgs: rec {
        buzz-acp = pkgs.callPackage ./packages/buzz-acp.nix { };
        buzz-cli = pkgs.callPackage ./packages/buzz-cli.nix { };
        buzz-relay = pkgs.callPackage ./packages/buzz-relay.nix { };
        ferron = pkgs.callPackage ./packages/ferron.nix { };
        minio = pkgs.callPackage ./packages/minio.nix { };
        default = buzz-cli;
      };
    in
    {
      overlays.default = final: _prev: {
        buzz-acp = final.callPackage ./packages/buzz-acp.nix { };
        buzz-cli = final.callPackage ./packages/buzz-cli.nix { };
        buzz-relay = final.callPackage ./packages/buzz-relay.nix { };
        buzz-ferron = final.callPackage ./packages/ferron.nix { };
        buzz-minio = final.callPackage ./packages/minio.nix { };
      };

      packages = forAllSystems (system: mkPackages nixpkgs.legacyPackages.${system});

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);

      nixosModules = rec {
        ferron = import ./modules/ferron.nix { inherit self; };
        buzz-relay = import ./modules/buzz-relay.nix { inherit self; };
        buzz-relay-container = buzz-relay;
        buzz-acp = import ./modules/buzz-acp.nix {
          inherit self llm-agents;
        };
        default = {
          imports = [
            buzz-relay
            buzz-acp
          ];
        };
      };

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
                system.stateVersion = "25.11";
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
              self.nixosModules.buzz-relay-container
              {
                boot.isContainer = true;
                system.stateVersion = "25.11";
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
                system.stateVersion = "25.11";
                services.buzz-acp = {
                  enable = true;
                  relayUrl = "wss://relay.example.test";
                  environmentFile = "/run/keys/buzz-agent.env";
                  codexAcp.enable = true;
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
                system.stateVersion = "25.11";
                services.buzz-acp = {
                  enable = true;
                  relayUrl = "wss://relay.example.test";
                  environmentFile = "/run/keys/buzz-agent.env";
                  claudeAcp.enable = true;
                };
              }
            ];
          };
          ferronConfig = pkgs.writeText "buzz-relay-ferron.conf" directRelay.config.services.ferron.configText;
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
            assert codexAgent.config.systemd.services ? buzz-acp;
            assert
              claudeAgent.config.systemd.services.buzz-acp.environment.BUZZ_ACP_AGENT_COMMAND
              == "${llm-agents.packages.${system}.claude-agent-acp}/bin/claude-agent-acp";
            pkgs.runCommand "buzz-nixos-module-evaluation" { } ''
              touch "$out"
            '';
        }
      );
    };
}
