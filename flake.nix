{
  description = "Nim development environment for decompbound";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
    in {
      devShells.${system}.default = pkgs.mkShell {
        name = "decompbound-dev";

        buildInputs = with pkgs; [
          nim
          nimble
          pkg-config
          stdenv.cc.cc.lib
          xorg.libX11
          xorg.libXext
          xorg.libXcursor
          xorg.libXrandr
          xorg.libXi
          libGL
          udev
          libevdev
          zlib
          curl
        ];

        shellHook = ''
          # Native libraries for windy (windowing) + paddy (gamepad, evdev/udev on Linux).
          export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath [
            pkgs.stdenv.cc.cc.lib
            pkgs.xorg.libX11
            pkgs.xorg.libXext
            pkgs.xorg.libXcursor
            pkgs.xorg.libXrandr
            pkgs.xorg.libXi
            pkgs.libGL
            pkgs.udev
            pkgs.libevdev
            pkgs.zlib
            pkgs.curl
          ]}:$LD_LIBRARY_PATH"

          echo "decompbound dev shell ready (paddy + windy supported)"
          echo "Example: nim r src/tools/play.nim bin/Earthbound\\ \\(U\\)\\ \\[\\!\\].smc"
        '';
      };
    };
}
