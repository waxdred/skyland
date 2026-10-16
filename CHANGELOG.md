# Changelog

skyland is a fork of [AeroSpace](https://github.com/nikitabobko/AeroSpace): everything
AeroSpace does still works; this file lists what skyland adds. Each `## vX.Y.Z` section
is also the text of its GitHub release.

## Unreleased

**Hyprland**
- **Window swallowing** (`[swallow]`): a window started from a terminal (`mpv`, `imv`, a
  GUI binary run from the shell) takes the terminal's place; the terminal comes back when
  it closes.
- **Dim inactive windows** (`[decoration] dim-inactive`, percent, also in the settings
  window): unfocused windows are darkened, fading with focus. Needs the Dock payload
  rebuilt (`skyland sa build && skyland sa load`).

**Install**
- `skyland sa load` offers to write the sudoers rule (payload injected at login without
  a password) and renews it after each rebuild of the payload.

## v0.1.4

**Settings window**
- **Save / Revert**: changes wait for Save (`cmd-s`), then the config is written and
  reloaded once. Moving a slider no longer rewrites the file at every step (lag).
- Themed with the current skyland theme: accent on the controls, `// SECTION` headers,
  translucent blurred background, dark / light from the theme.

**Themes**
- New **`cyberpunk`** theme: near black violet, neon red accent, cyan highlight
  (`alt-shift-l`).

**Install**
- **Homebrew**: `brew install waxdred/tap/skyland`, then `skyland install`. The tap is
  updated by each release.

## v0.1.3

**Install**
- From a release zip or Homebrew, the config is **copied** to `~/.config` once and is
  yours: an update only adds new files (themes), never overwrites your edits. A git
  clone still links `~/.config` to the repo.
- Paths go through Homebrew's `opt/skyland`, which survives upgrades.

## v0.1.2

**macOS appearance** (optional, `[appearance]`)
- macOS **dark / light** follows skyland (`alt-l`, wallpaper brightness).
- **Accent color**: the macOS preset closest to the theme accent.
- **Highlight color**: the exact theme accent (any color, not only the 8 of System
  Settings). `skyland appearance restore` puts your old values back.

**System prompts**
- Unlock, permission (Accessibility, Automation, privacy), keychain and Touch ID
  windows stay in front: focus follows mouse pauses while one is on screen, and with
  the Dock payload they are raised above floating windows.

## v0.1.1

**Fixes**
- The release app crashed at start (default config looked up in the CI build folder).
- `skyland install` trusts the sketchybar tap (recent Homebrew) and no longer upgrades
  packages you already have.
- The sketchybar hook uses the full path to `skyland` (sketchybar has a short PATH).
- Quitting skyland resets window transforms; windows no longer stay drawn at their
  animated position after an uninstall.

## v0.1.0

First release.

**Tiling, Hyprland style**
- **dwindle** layout with smart split (the side follows the cursor), `togglesplit`.
- **master** layout per workspace (`alt-shift-t`), centered on ultrawide screens,
  `swapwithmaster` (`alt-shift-enter`).
- **groups** with a tabs bar (`alt-g`, `alt-n`, `alt-ctrl-arrows`).
- **scratchpads**, named ones too (`alt-s`, `alt-a` = Spotify).
- **window rules** (floating utilities, apps sent to a workspace).
- **alt + mouse** move / resize anywhere on a window.
- 12 workspaces, 4 per screen, kept across restarts.

**Look** (window effects need SIP partially disabled, like yabai)
- Bezier **animations**: windows pop in, shrink and fade on close, `slidefadevert`
  workspace switch, fades.
- Rounded corners, active / inactive opacity, floating windows on top.
- Focused window **border** in the theme accent (JankyBorders), Ghostty blur.

**Themes and wallpapers**
- 18 **43PR themes**, theme picker (`alt-shift-l`), light / dark (`alt-l`).
- **Wallpaper picker** (`alt-w`), colors generated from the wallpaper (matugen), light or
  dark picked from its brightness, wallhaven collections download.

**Tools**
- **Workspace overview** (`cmd-up`) with live thumbnails, drag windows between workspaces.
- **Settings window** (`alt-i`): visual settings, key recorder, per-app rules.
- **Shortcut cheat sheet** (`alt-shift-h`), window management on / off (`alt-r`).
- Lock screen saver (`alt-tab`), floating media widget with audio-reactive bars (`alt-m`).
- sketchybar integration, the auto-hidden macOS menu bar shows over it on hover.

**Install**
- `bin/skyland-install` (dependencies, Swift, signing, build, start), `skyland doctor`,
  `skyland uninstall`, one `skyland` CLI.
