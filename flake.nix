{
  description = "Pinned Dune environment for the source-only tree_of_md CI build";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/70ce234312134a463ba7728e94da2486a1d237ac";

  outputs = { nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in {
      devShells = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; };
        in {
          default = pkgs.mkShell {
            # OCaml and its libraries come from the existing dune.lock, not Nix.
            packages = with pkgs; [
              dune gnumake git pkg-config libyaml python3 autoconf automake patch
            ];
          };
        });
    };
}
