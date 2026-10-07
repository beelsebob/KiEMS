{
  description = "KiEMS C++ development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in {
      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          python = pkgs.python3.withPackages (ps: [
            ps.matplotlib
          ]);
        in {
          default = pkgs.mkShell {
            packages = with pkgs; [
              python
              cmake
              ninja
              pkg-config
              stdenv.cc
              nlohmann_json
              geos
              gnuplot
              hdf5
              blosc2
              cgal
              boost
              gmp
              mpfr
              vtk
              wxwidgets_3_2
              gtk3
              glm
              cairo
              pixman
              freetype
              harfbuzz
              opencascade
              ngspice
              libspnav
              libgit2
              nng
              zstd
              protobuf
              fontconfig
              unixODBC
            ];

            shellHook = ''
              echo "KiEMS Nix development shell ready. Configure with: cmake --preset linux-debug"
            '';
          };
        });
    };
}
