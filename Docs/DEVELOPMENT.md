# Development and releases

## Layout

| Path | Purpose |
| --- | --- |
| `OBSAPNGPlugin.dpr` | OBS module exports and runtime compatibility check |
| `Source/PNGDecoder.pas` | PNG decompression, row filters, sample expansion and Adam7 |
| `Source/APNGDecoder.pas` | APNG parsing, frame compositing, caching and timing |
| `Source/OBSAPNGSource.pas` | OBS properties, animation clock and texture rendering |
| `Tests/` | Decoder fixtures, benchmark and optional OBS integration probe |
| `Docs/` | Developer documentation and coding style |
| `.github/` | Decoder CI and issue templates |
| `Bin/`, `.build/`, `Dist/` | Generated files; excluded from Git |

## Binding dependency

Use [DelphiOBS v0.2.0](https://github.com/nalilord/DelphiOBS/tree/v0.2.0),
commit `950124534495f58b82344710655286b60dd318f6`. It targets the OBS 33.0.1
headers while retaining the common 32.1.2 module ABI. The bindings are not copied
into this repository. Build scripts default to a sibling `OBSPlugin` directory;
`-OBSPluginRoot` in PowerShell or `OBS_PLUGIN_ROOT` in WSL overrides it.

The project resolves binding units through the compiler search path. When
building in the IDE, set that path explicitly. Do not raise the exported module
API just because the bindings target newer headers: review the actual imports
and test the supported OBS runtimes first.

## Implementation

Frames are decoded once and composited in straight RGBA. For OBS, completed
frames are copied into a premultiplied cache during loading. Rendering selects
the frame with binary search and uploads its pixels only when the frame changes.
Speed scales increments of the animation clock, preserving the position when
settings change.

PNG decoding consumes IDAT/fdAT data directly. DEFLATE is handled by Delphi's
statically linked `System.ZLib`; filtering, sample conversion and APNG compositing
are Pascal. The Linux test build uses FPC's ZLib binding and system libz.
Inflate output is bounded by the expected scanline size. At the maximum dimensions,
the RGBA16 inflate buffer can require about 128 MiB in addition to the canvas,
frame cache and other scratch buffers.

Changes to thread synchronization must preserve graphics-before-source-lock
ordering. OBS renders with its graphics lock already held. Loading happens
before taking that graphics lock; the finished animation is then swapped in.

## Release preparation

1. Update `VERSION` and `CHANGELOG.md`.
2. Build and run the Windows decoder suite with `build.ps1 -Tests`.
3. Run the OBS render probe against the supported runtime versions. See
   [TESTING.md](TESTING.md).
4. Run `package-plugin.ps1 -Tests`. It builds from source and creates:
   - `Dist/OBSAPNGSource-<version>-windows-x64.zip`
   - `Dist/SHA256SUMS.txt`
5. Review the ZIP, commit the source, then tag the release as `v<version>`.
6. Attach the ZIP and checksum file to the GitHub release for that tag. GitHub
   also supplies source archives for the tag; keep the tested dependency reference
   documented so the build is reproducible.

The ZIP contains the DLL in `obs-plugins/64bit`, installation instructions, the
project license and third-party notices. Do not add compiled binaries, test
captures, compiler units or local runtime installations to Git.

The first public release is version 0.1.0. Creating a package does
not create a GitHub repository, tag, release or upload.
