# Contributing

Build instructions are in the [README](README.md#build-from-source). Use
[DelphiOBS v0.2.0](https://github.com/nalilord/DelphiOBS/tree/v0.2.0) for the tested
bindings baseline, and follow the [Pascal coding style](Docs/CODE_STYLE.md).

For a bug report, include the plugin and OBS versions, Windows version, what you
expected, what happened, and the relevant `[obs-apng]` log messages. A small APNG
that reproduces the issue is especially helpful. Share only files you have
permission to publish and remove private information from logs.

Keep pull requests focused. Explain the behavior change and how you checked it.
Decoder changes should pass the fixture suite; rendering, timing and OBS API
changes should also be exercised in the isolated render probe. See
[TESTING.md](Docs/TESTING.md). Do not commit build output or test captures.

Contributions are provided under the project's GNU GPL v2 license.
