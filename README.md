# APNG Source for OBS Studio

![Platform: Windows x64](https://img.shields.io/badge/platform-Windows_x64-0078D4)
![OBS: 32.1.2–33.x](https://img.shields.io/badge/OBS-32.1.2%E2%80%933.x-302E31)
![Language: Delphi](https://img.shields.io/badge/language-Delphi-E62431)
[![License: GPL v2](https://img.shields.io/badge/license-GPL_v2-blue)](LICENSE)
[![Decoder tests](https://github.com/nalilord/OBSAPNGSource/actions/workflows/decoder.yml/badge.svg)](https://github.com/nalilord/OBSAPNGSource/actions/workflows/decoder.yml)

Play animated PNG overlays directly in OBS with transparency, adjustable speed
and the timing stored in the file. Add **APNG Image**, choose an animation, and
place it in your scene.

The plugin decodes the animation when you load it and caches the completed
frames. Playback uploads a frame only when it changes. PNG decoding and APNG
compositing are implemented in Delphi, using the RTL's bundled zlib for DEFLATE.
There is no WIC/COM decoding, browser source or additional codec DLL to install.

## Features

- **Transparent overlays:** full alpha, partial frames and correct APNG blending/disposal.
- **Playback speed:** 1–1000%. Use 100% for original timing, 50% for half speed or 200% for double speed.
- **Loop control:** loop continuously or follow the play count stored in the APNG.
- **Show/hide behavior:** restart when shown, or resume from the paused position.
- **Reload button:** pick up edits to a file without recreating the source.
- **PNG coverage:** grayscale, RGB, palette, alpha, all legal bit depths and Adam7 interlacing.

This is a dedicated source for short APNG overlays, borders and animated graphics.
It caches full frames in memory, so it is best suited to overlay assets rather
than long animations.

## Requirements

| Component | Supported / tested |
| --- | --- |
| Operating system | Windows x64 |
| OBS Studio | 32.1.2 or newer in the 32.x and 33.x series |
| Runtime validation | OBS 32.2.2 and 33.0.1 with Direct3D 11 |
| Extra runtime packages | None |

OBS 32.1.2 is the declared minimum; it has not been tested directly. Linux and
macOS plugin builds are not provided. The decoder can be tested separately on Linux.

## Install

[Download the Windows x64 plugin](https://github.com/nalilord/OBSAPNGSource/releases/latest),
or [build it from source](#build-from-source). GitHub's automatically generated **Source
code** archives contain source files, not an installable DLL.

1. Close OBS Studio.
2. Extract the plugin ZIP and merge its `obs-plugins` folder into your OBS
   installation directory—the directory containing `bin`, `data` and `obs-plugins`.
   The DLL should end up at `obs-plugins/64bit/OBSAPNGPlugin.dll`.
3. Start OBS. In **Sources**, select **+ → APNG Image**.
4. Choose your `.apng` or animated `.png` file.

For a local build, copy `Bin/Win64/OBSAPNGPlugin.dll` to that same destination.
When updating, close OBS before replacing the DLL. To uninstall, close OBS and
remove `OBSAPNGPlugin.dll`.

## Playback controls

| Setting | Behavior |
| --- | --- |
| Animated PNG | The file to load. Ordinary, non-animated PNGs are rejected. |
| Loop continuously | Enabled by default. Disable it to honor the file's play count; zero means infinite. |
| Restart animation when shown | Enabled by default. Disable it to resume after the source was hidden. |
| Playback speed | Defaults to 100%. Changing it preserves the current position and does not reload the file. |
| Reload file / restart | Reloads the selected file and starts from the beginning. |

Each frame's delay comes from the APNG. Speed scales that timing; the duration
shown in the load status is the duration at **100%**. OBS's output frame rate
limits how often a visible frame change can occur. Very fast animations can skip
frames, and slowing down an animation does not create interpolated frames.

## Limits and troubleshooting

The decoder accepts up to **64 MiB of input**, **4096 × 4096 pixels**, **1024 frames**
and **256 MiB of cached RGBA frames**. Scratch buffers and the GPU texture need
additional memory. Cached memory is approximately `width × height × 4 × frames`:
a 512 × 288 animation with 60 frames uses about 33.8 MiB for the cache.

- **Empty source:** check the status in Properties and the OBS log for `[obs-apng]`.
  Invalid files, ordinary PNGs and animations exceeding the limits are rejected.
- **File changed on disk:** press **Reload file / restart**; there is no file watcher.
- **Timing differs from a browser:** frame delays shorter than 1 ms are clamped to 1 ms.
- **Color differences:** 16-bit samples are reduced to 8-bit; embedded color profiles
  and gamma metadata are not applied. Rendering uses OBS's sRGB convention.

## Build from source

The Windows plugin requires a Delphi Win64 compiler. Development builds use
Delphi 13 / compiler 37.0. Node.js is required only for the decoder tests.

The shared OBS bindings are provided by
[DelphiOBS](https://github.com/nalilord/DelphiOBS), tested at **v0.2.0**. Clone that
release beside this project, naming its directory `OBSPlugin`:

```powershell
# From the parent directory containing OBSAPNGSource:
git clone --branch v0.2.0 --depth 1 https://github.com/nalilord/DelphiOBS.git OBSPlugin
cd OBSAPNGSource
.\Scripts\build.ps1 -Tests
```

The result is `Bin/Win64/OBSAPNGPlugin.dll`. The build script discovers Delphi
under Program Files (x86). Use `-DelphiRoot` or `-OBSPluginRoot` to override either
location:

```powershell
.\Scripts\build.ps1 -DelphiRoot 'C:\Path\To\Studio\37.0' -OBSPluginRoot 'D:\Source\DelphiOBS' -Tests
```

For the IDE, open `Source/OBSAPNGPlugin.dpr`, select Win64, and add
`..\..\OBSPlugin\Source` to the unit search path (relative to the DPR).
WSL users can run `bash Scripts/build.sh -Tests`; `OBS_PLUGIN_ROOT` overrides
the bindings directory. The wrapper accepts the same switches, including `-Package`.

Build a release ZIP and checksum file with:

```powershell
.\Scripts\build.ps1 -Package -Tests
```

See [development and release notes](Docs/DEVELOPMENT.md) for the project layout
and packaging workflow.

## Tests and performance

The decoder suite contains **239 cases** covering pixel output, PNG variants,
APNG compositing, playback timing and corrupt input. It has passed on Delphi
Win64 and Free Pascal/Linux. The plugin has also passed isolated rendering,
Properties, recovery and shutdown checks on OBS 32.2.2 and 33.0.1, including
50%, 100% and 200% playback speeds.

```bash
# Decoder-only tests on Linux; requires FPC, Node.js and libz.
bash Tests/run-native.sh
```

A GitHub Actions workflow runs the Linux decoder suite. It does not build the
Windows plugin or replace OBS integration testing. See [testing and benchmark
notes](Docs/TESTING.md) for requirements, the render probe and measured results.

## License

Created by **NaliLord**. Licensed under the [GNU GPL v2](LICENSE).
[DelphiOBS](https://github.com/nalilord/DelphiOBS) supplies the shared OBS bindings;
[third-party notices](THIRD_PARTY_NOTICES.txt) describe the dependencies.
This is an independent project and is not affiliated with or endorsed by OBS Studio.
