{
  description = "Tern terminal multiplexer package";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
    }:
    let
      mkPkgs =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
    in
    {
      packages =
        (nixpkgs.lib.genAttrs [
          "x86_64-linux"
          "aarch64-linux"
          "aarch64-darwin"
        ])
          (
            system: with (mkPkgs system); rec {
              default = callPackage ./pkgs/tern.nix { };
              tern = tern;
              tern-login-shell = tern.passthru.loginShell;
            }
          );

    };
}
