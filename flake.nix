{
  description = "libvaxis";
  inputs = {
    nixpkgs = {
      url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    };
    zig = {
      url = "git+https://git.ocjtech.us/jeff/zig-overlay.git";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };
  };
  outputs =
    {
      nixpkgs,
      zig,
      ...
    }:
    let
      lib = nixpkgs.lib;
      platforms = lib.attrNames zig.packages;
      packages =
        system:
        import nixpkgs {
          inherit system;
        };
      forAllSystems = (function: nixpkgs.lib.genAttrs platforms (system: function (packages system)));
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          name = "libvaxis";
          nativeBuildInputs = [
            zig.packages.${pkgs.stdenv.hostPlatform.system}.master
          ];
        };
      });
    };
}
