{
  inputs.nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0";

  outputs =
    { self, ... }@inputs:
    let
      inherit (inputs.nixpkgs) lib;

      forEachSystem =
        f:
        lib.genAttrs lib.systems.flakeExposed (
          system:
          f {
            inherit system;
            pkgs = import inputs.nixpkgs {
              inherit system;
              config.allowUnfree = true;
            };
          }
        );
    in
    {
      devShells = forEachSystem (
        { pkgs, system }:
        {
          default = pkgs.mkShellNoCC {
            name = "k0s";

            packages = with pkgs; [
              self.formatter.${system}
              cilium-cli
              curl
              jq
              kubectl
              kubernetes-helm
              opentofu
              oras
              step-cli
              yq
            ];

            shellHook = ''
              ln -sf "${pkgs.cilium-cli}/bin/cilium" cilium
              mkdir -p $PWD/.local/oras
              export STEPPATH="$PWD/.local/step"
              export ORAS_CACHE="$PWD/.local/oras"
              if make gen-kubeconfig &> /dev/null; then
                . activate.sh > /dev/null 2>&1
              fi
            '';
          };
        }
      );

      formatter = forEachSystem ({ pkgs, ... }: pkgs.nixfmt-tree);
    };
}
