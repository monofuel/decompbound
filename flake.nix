{
  description = "Nim development environment for decompbound";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs }:
    {
      devShells.x86_64-linux.default =
        let
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
          # windy (the game player window) dlopens these at runtime.
          runtimeLibs = with pkgs; [
            xorg.libX11
            xorg.libXext
            xorg.libXcursor
            xorg.libXrandr
            xorg.libXi
            libGL
          ];
        in
        pkgs.mkShell {
          buildInputs = with pkgs; [
            nim
            nimble
          ] ++ runtimeLibs;

          shellHook = ''
            export LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath runtimeLibs}:$LD_LIBRARY_PATH
          '';
        };
    };
}
