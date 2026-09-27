# Geometry backend

KiEMS requires GEOS 3.10 or newer and uses its stable C API (`geos_c`) for polygon unions, intersections, differences,
offsets, point containment, and constrained Delaunay triangulation. Geometry remains in
double-precision simulation coordinates throughout; there is no integer scaling or rounding at the
library boundary.

The Xcode project expects a Homebrew-style GEOS installation under `/opt/homebrew`:

```sh
brew install geos
```

GEOS is licensed under LGPL-2.1-or-later. KiEMS links to its shared C API library. Distributed builds
must retain the GEOS license notices and users' ability to replace the shared GEOS library, as
required by that license.
