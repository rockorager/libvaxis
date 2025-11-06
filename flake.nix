{
  description = "Libvaxis Development Environment";
  inputs = {
    nixpkgs-stable.url = "github:nixos/nixpkgs?ref=nixos-25.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs-stable, nixpkgs-unstable, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
     	let
    		stb = nixpkgs-stable.legacyPackages.${system};
        unstb = nixpkgs-unstable.legacyPackages.${system};
     	in {
        devShells.default = stb.mkShell {
       	  packages = with unstb; [
            zig
            zls
            lldb
         	];
          shellHook = ''
            export NIX_SHELL_NAME="libvaxis";
          '';
        };
      }
    );
}
