{
  description = "A Nix-flake-based Odin development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = {
    self,
    nixpkgs,
  }: let
    supportedSystems = [
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
    ];

    forEachSupportedSystem = f:
      nixpkgs.lib.genAttrs supportedSystems (
        system:
          f {
            pkgs = import nixpkgs {
              inherit system;
              overlays = [self.overlays.default];
            };
          }
      );
  in {
    overlays.default = final: prev: {
      odin = prev.odin.overrideAttrs rec {
        version = "dev-2025-12";

        src = prev.fetchFromGitHub {
          owner = "odin-lang";
          repo = "Odin";
          tag = version;
          hash = "sha256-YN/HaE8CD9xQzRc2f07aBy/sMReDj1O+U0+HPKBYFmQ=";
        };
      };
    };

    devShells = forEachSupportedSystem (
      {pkgs}:
        with pkgs; {
          default = mkShell {
            nativeBuildInputs = [
              odin
            ];

            buildInputs = [
              vulkan-tools
            ];

            packages = [
              # debugging
              lldb

              # language support
              ols
              nixd
              alejandra
              vscode-json-languageserver
            ];

            XDG_SESSION_TYPE = "x11"; # wayland can't handle fullscreen
          };
        }
    );
  };
}
