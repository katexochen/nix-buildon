{
  inputs.nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      forAllSystems =
        function:
        nixpkgs.lib.genAttrs [
          "x86_64-linux"
          "aarch64-linux"
        ] (system: function nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: {
        default = pkgs.writeShellApplication {
          name = "nix-buildon";
          runtimeInputs = with pkgs; [
            coreutils
            disorderfs
            e2fsprogs
            btrfs-progs
            gnused
            systemd
            nix
          ];
          text = builtins.readFile ./bulidon.sh;
        };
      });
    };
}
