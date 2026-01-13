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
        with pkgs; let
          dev = writeShellScriptBin "dev" ''
            export DYLD_LIBRARY_PATH="${lib.makeLibraryPath [vulkan-loader moltenvk]}"
            export VK_LAYER_PATH="${vulkan-validation-layers}/share/vulkan/explicit_layer.d"
            export VK_ICD_FILENAMES="${moltenvk}/share/vulkan/icd.d/MoltenVK_icd.json"
            odin build src/render/vulkan -out:vulkan && ./vulkan
          '';
        in {
          default = mkShell {
            nativeBuildInputs = [
              odin
            ];

            buildInputs = [
              vulkan-headers
              vulkan-loader
              vulkan-tools
              vulkan-validation-layers
              glfw
              moltenvk

              # shaders
              glslang
              shaderc
            ];

            packages = [
              # debugging
              lldb

              # language support
              ols
              nixd
              alejandra
              vscode-json-languageserver

              # dev tools
              dev
            ];

            VK_LAYER_PATH = "${vulkan-validation-layers}/share/vulkan/explicit_layer.d";
            VK_ICD_FILENAMES = "${moltenvk}/share/vulkan/icd.d/MoltenVK_icd.json";
            DYLD_LIBRARY_PATH = lib.makeLibraryPath [vulkan-loader moltenvk];
          };
        }
    );
  };
}
