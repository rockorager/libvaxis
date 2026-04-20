{
  description = "libvaxis";
  inputs = {
    nixpkgs = {
      url = "https://channels.nixos.org/nixos-unstable-small/nixexprs.tar.xz";
    };
  };
  outputs =
    {
      nixpkgs,
      ...
    }:
    let
      platforms = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
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
            pkgs.fd
            pkgs.neovim
            pkgs.pinact
            pkgs.zig_0_16
          ];
        };
      });
    };
}
