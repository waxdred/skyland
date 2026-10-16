# Contributing

skyland is a fork of [AeroSpace](https://github.com/nikitabobko/AeroSpace). Bugs and
ideas about skyland's own features (layouts, animations, themes, scripts, install) go to
[skyland's issues](https://github.com/waxdred/skyland/issues). A bug that also happens
in plain AeroSpace belongs upstream, in
[AeroSpace's discussions](https://github.com/nikitabobko/AeroSpace/discussions).

## Reporting a bug

- `skyland doctor` output
- `skyland debug-windows` output, if the problem is about some windows
- your config (`~/.config/aerospace/aerospace.toml`), macOS version, skyland version
  (release tag, or `git rev-parse --short HEAD` for a clone), whether the Dock payload is loaded (`skyland sa send ping`)
- a screenshot or a short video for anything visual

## Where the code lives

| Path | What |
|---|---|
| `Sources/AppBundle/skyland/` | skyland's additions to the window manager (Swift): animations, decorations, master layout, groups, overview, settings window, scratchpads... |
| `Sources/AppBundle/` (the rest) | AeroSpace: keep changes there small, they are merged with upstream |
| `Sources/AppBundleTests/skyland/` | tests of the additions |
| `osax/` | Dock payload (Objective-C, arm64e): corners, opacity, transforms, layers |
| `bin/` | the `skyland` CLI and its scripts (bash) |
| `profiles/hypr/` | default config, themes, sketchybar items |
| `tools/` | helper apps: shortcut cheat sheet, lock screen saver, media widget |

## Build and test

```sh
bin/skyland-build           # Swift from .swift-version through swiftly, signs Skyland.app
swiftly run swift test      # must pass, CI runs it on every push
skyland sa build            # Dock payload (needs SIP partially off to load: skyland sa load)
```

Restart the app with `open .build/Skyland.app`.

## Sending a change

- Open a pull request against `main`. Small and focused beats big.
- Look like the code around it: same naming, comment density and idioms. Swift is
  checked by `./lint.sh` (swiftformat, swiftlint); bash scripts start with a usage
  comment and `set -euo pipefail`.
- Add a test for logic (layouts, config parsing) in `Sources/AppBundleTests/skyland/`.
- A user-visible change gets a line in the `## Unreleased` section of `CHANGELOG.md`;
  a new config key or binding goes in `README.md` and the default config.

By contributing, you agree to license your changes under the MIT license.
