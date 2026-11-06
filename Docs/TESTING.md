# Testing and benchmarks

## Decoder tests

On Windows, run `build.ps1 -Tests` from the project root. This requires Delphi
Win64, the DelphiOBS bindings described in the README, and Node.js on PATH.
`Tests/test-decoder.cjs` uses Node built-ins to generate its own fixtures and
compare decoded pixels with expected results; no npm packages or external
artwork are required.

The 239 cases cover all legal PNG color/depth combinations, all five row filters,
Adam7 including empty passes, palette alpha, full-precision tRNS matching,
partial frames, SOURCE/OVER and all disposal modes. They also check timing,
finite/infinite plays, hidden default images, premultiplied cache pixels,
checksums, malformed input, sequence/order errors and allocation bounds.

For Linux decoder testing, install Free Pascal with the FCL and ZLib units,
Node.js, and system libz. On Ubuntu:

```bash
sudo apt-get install fp-compiler fp-units-base fp-units-fcl zlib1g-dev nodejs
bash Tests/run-native.sh
```

The test build enables range and overflow checks. The script then compiles an
optimized load-time benchmark. It does not build the Windows plugin or validate
OBS APIs. The GitHub Actions workflow runs the same decoder script.

## OBS rendering

`Tests/run-render.ps1` builds and runs the existing `OBSRenderProbe.dpr` against
a supplied OBS installation. It generates a 508 × 286, three-frame test border
with an opaque rim, transparent center and a semitransparent patch. Run from the
project root after `build.ps1`:

```powershell
.\Tests\run-render.ps1 -OBSRoot 'C:\Program Files\obs-studio'
```

The driver runs 45 captures at each of 50%, default 100% and 200%, verifies source
creation, Properties, settings, missing-file recovery and shutdown, then checks
pixel consistency, alpha and approximate frame-transition counts. It uses an
isolated libobs instance and does not open the GUI or modify live scenes.
It needs a working Direct3D 11 adapter and a complete OBS runtime. Headless CI
cannot replace this check. Captures and logs are written under `.build/render-tests`.

The probe can also be invoked directly with five required arguments: plugin DLL,
508 × 286 APNG, libobs effects directory (with trailing slash), graphics DLL and
capture directory. The optional sixth argument selects speed in percent.

The November 6, 2026 build passed on OBS 32.2.2 and 33.0.1. Both runtimes produced
7, 15 and 30 transitions across 45 captures at 50%, 100% and 200% respectively,
and all distinct captured frames matched the earlier build byte-for-byte.
Earlier validation also compared the native and original WIC builds against
one another with matching pixel output. These are synthetic-fixture checks,
not a guarantee for every asset or GPU.

## Load-time benchmark

Build `Tests/DecodeBenchmark.dpr` with Delphi, or let `Tests/run-native.sh` build
the Linux version. From WSL:

```bash
bash build-wsl-generic.sh Tests/DecodeBenchmark.dpr Win64
```

Run `DecodeBenchmark input.apng [iterations=30] [straight]`. The optional
`straight` flag omits premultiplication; default output is the upload-ready cache.
The first load warms the file cache, and the timed loop excludes startup and
writing decoded frames to disk. This is a load-time measurement, not a GPU or
OBS rendering benchmark.

Historical measurements on the generated 512 × 288, 12-frame RGBA fixture,
using Delphi 37.0/Win64 on the same machine, three rounds of 100 loads:

| Path | Time per load |
| --- | --- |
| Original WIC decoder, straight RGBA | 16.87–17.19 ms |
| Native decoder, straight RGBA | 9.84–10.00 ms |
| Native decoder, premultiplied OBS cache | 20.31–20.78 ms |

Equivalent straight-RGBA loading took about 42% less time on this fixture.
Preparing the premultiplied cache adds load-time work but removes the conversion
and pixel copy previously performed for every displayed frame on every loop.
Actual performance depends on dimensions, filters, compression, frame count,
blend/disposal modes, compiler and hardware. The obsolete WIC implementation and
local benchmark artifacts are not included in the public repository.
