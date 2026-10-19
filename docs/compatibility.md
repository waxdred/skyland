# Compatibility

What has been checked on which macOS, and how. A version that is not listed has not been
tested: it may work, report it with the checks below.

skyland needs an **Apple Silicon** Mac. The app is built for macOS 13 and later, but it is
only run and tested on the versions below.

| macOS | Tiling, workspaces, overview, themes (SIP on) | Window effects (Dock payload, SIP partly off) | Liquid Glass panels | Checked |
|---|---|---|---|---|
| 27.0.1 | yes | yes: corners, opacity, dim, animations, fades, Dock guard | Apple's glass | 2026-10-19: `tools/e2e-visibility` 40 rounds, payload `kill -9` guard, `skyland sa build` tests |
| 26.x | not tested | not tested | Apple's glass expected | — |
| 15.6.1 (24G90) | yes | yes: the SkyLight signatures were recovered on this build | shader / blur (no Apple glass before 26) | 2026-10-14 to 10-16, by hand |
| 14 and older | not tested | not tested | shader / blur | — |

## What can break with a macOS update

- **The window effects.** They go through private SkyLight functions called from a payload
  injected into Dock (`osax/payload.m`). Apple can rename or change them in any update. When
  that happens, the payload's commands fail and skyland runs without effects. Tiling and
  everything in the left column do not use them.
- **The payload's injection.** It needs the `-arm64e_preview_abi` boot-arg and the arm64e ABI
  that Dock uses (`skyland sa build` prints `abi: USR00`). A new ABI needs a rebuild flag.
- **The build.** A new Command Line Tools SDK can break the Swift toolchain's linker (with the
  macOS 27 SDK, Swift 6.4.1 fails with `libSystem.B.tbd: unknown architecture`). Build against
  the previous SDK until the toolchain catches up:
  `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk bin/skyland-build`.

## Checking a version

```sh
skyland doctor                          # permissions, payload, dependencies
SDKROOT=... bin/skyland-sa build        # payload and its unit tests ("payload ok")
swiftc -O tools/e2e-visibility.swift -o .build/e2e-visibility
.build/e2e-visibility 11 12 40          # two spare workspaces; hands off for 2 minutes
```

`e2e-visibility` opens Calculator windows, then switches, moves, closes and opens windows at
random, and fails if a window of the shown workspace ends up off screen or see-through.

To check the Dock guard: make a window fade (`skyland-sa send fade <id> 0 8000 0 0 1 1`),
`kill -9` Skyland halfway, and the window must be opaque again within a second.
