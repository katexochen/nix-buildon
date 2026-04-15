{
  inputs.nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      overlay = final: prev: {
        disorderfs = final.stdenv.mkDerivation (finalAttrs: {
          pname = "disorderfs";
          version = "0.6.2";
          src = final.fetchFromGitLab {
            domain = "salsa.debian.org";
            owner = "reproducible-builds";
            repo = "disorderfs";
            tag = "${finalAttrs.version}";
            hash = "sha256-1ehGbNYbOewnDrQ1JhozKMvfVaCH7sDCxrD0dvwAfw0=";
          };
          nativeBuildInputs = with final; [
            pkg-config
            asciidoc-full
          ];
          buildInputs = with final; [
            fuse3
            attr
          ];
          NIX_CFLAGS_COMPILE = [ "-D_FILE_OFFSET_BITS=64" ];
          installFlags = [ "PREFIX=$(out)" ];
        });
      };
      forAllSystems =
        function:
        nixpkgs.lib.genAttrs [
          "x86_64-linux"
          "aarch64-linux"
        ] (system: function (nixpkgs.legacyPackages.${system}.extend overlay));
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
