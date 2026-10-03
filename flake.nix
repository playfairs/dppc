{
  description = "D++ compiler toolchain and development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nox.url = "github:playfairs/nox";
  };

  outputs = { self, nixpkgs, nox }:
    let
      system = "aarch64-darwin";
      pkgs = import nixpkgs {
        inherit system;
      };
      dToolchain = [ pkgs.ldc ]
        ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
          pkgs.dmd
        ];
    in
    {
      packages.${system}.default = pkgs.stdenv.mkDerivation {
        pname = "dpp";
        version = "0.2.0";
        src = self;

        nativeBuildInputs = [
          nox.packages.${system}.default
          pkgs.clang
        ] ++ dToolchain;

        buildPhase = ''
          nox setup build --reconfigure
          nox compile -C build
        '';

        installPhase = ''
          mkdir -p $out/bin
          mkdir -p $out/lib
          mkdir -p $out/include/dpp
          install -m755 build/debug/dpp/dpp $out/bin/dpp
          install -m644 build/debug/dpp_runtime/libdpp_runtime.a $out/lib/libdpp_runtime.a
          install -m644 runtime/include/dpp/runtime.h $out/include/dpp/runtime.h
        '';
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          nox.packages.${system}.default
          pkgs.clang
        ] ++ dToolchain;

        shellHook = ''
          export DPPC_ROOT="$PWD"
          echo "D++ development environment ready (Nox + D toolchain)."
          echo "Use: nox setup build && nox compile -C build"
        '';
      };
    };
}
