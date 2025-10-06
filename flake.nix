{
  description = "VDSM CI image build environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            pre-commit
            python3
            jq
          ];

          shellHook = ''
            echo "VDSM CI development environment"
            echo "Available commands:"
            echo "  ./build-image.sh - Build configured VDSM image"
            echo "  ./smoke-test.sh  - Test flattened image"
            echo "  pre-commit run --all-files - Run pre-commit hooks"
          '';
        };
      }
    );
}
