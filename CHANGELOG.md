# Changelog

skyland is a fork of [AeroSpace](https://github.com/nikitabobko/AeroSpace): everything
AeroSpace does still works; this file lists what skyland adds. Each `## vX.Y.Z` section
is also the text of its GitHub release.

## Unreleased

**Liquid Glass**
- Protected videos (Netflix, Prime Video) play again: the metal glass takes snapshots of
  what is behind instead of running a capture stream (macOS hides protected content while
  one runs, and the media widget's never stopped). A new snapshot when the front app
  changes, when the panel moves, and every 30 s.
- The media widget's audio bars and wave read the system's audio from a Core Audio tap
  (macOS 14.2), not a ScreenCaptureKit stream: protected videos went black as soon as they
  played with the widget open. macOS may ask once to let Skyland record the system's audio.

## v0.4.0

**Liquid Glass**
- skylandbar's glass in skyland's panels (`ui-style = 'glass'`): lightly tinted glass, the
  selection a lens of glass flowing on springs and leaving a drop behind, a lighter drop
  under the mouse. The window switcher, the overview and the wallpaper / theme pickers use
  it (`GlassSurface`); big blocks (cards, thumbnails) take a lens that slides in one piece,
  with rounder corners.
- The refraction stays within a shape's corner radius: it broke along the diagonal of the
  corners.
- No flash when a panel opens: Core Animation's glass stands in until the first capture,
  which used to show the panel clear, then darker for a few frames.
- Settings window in glass: the theme tint in the glass, under its rim, the save bar lightly
  tinted.
- Pickers: room around the thumbnails, whole ones only (none cut at the edge).
- Fixes: glass views added at 0 x 0 never grew (the media widget's glass was not drawn), the
  capture did not restart after a drag, and the Metal texture cache kept every frame's
  surface.

**Media widget**
- Its own drag from the mouse position: it no longer lags behind or keeps moving after the
  button is released, and the audio wave keeps playing while it moves.
- A defined glass edge (one rim, no hairline over it), radius 26.

**skylandbar**
- `subscribe` event `workspace-swipe`: while a trackpad swipe moves, `workspace`,
  `targetWorkspace` and `progress`. skylandbar's workspace lens follows the fingers.

**Process name**
- The process is named `Skyland` (it was `AeroSpaceApp`) in Activity Monitor, btop and
  `pkill -x Skyland`; the app's executable is `Skyland.app/Contents/MacOS/Skyland`.

**Fixes**
- Quitting never waits for good on a window's frame: a window whose frame could not be read,
  or an app that did not answer, left skyland stuck (no CLI, no keys, `kill -9` only).

## v0.3.0

**Overview**
- Typing searches the windows by app or title (`/` for the letters the overview binds):
  the others are dimmed, on the cards and behind; enter focuses the selection.
- Keyboard selection of windows (`j` / `k`, up / down, tab), `enter` focuses it, `x` or a
  middle click closes a window, the overview stays open.
- A `+` card: a window dropped there goes to the first empty workspace of the screen.
- alt + drag a card onto another: the two workspaces swap their windows, layout and
  floating windows included.
- Pinned windows show on every card of their screen.
- `overview next|prev|confirm|close|search` command for `[mode.overview.binding]`.

**Login**
- skyland starts skylandbar when it is installed (`~/.local/bin` or Homebrew) and not
  running yet, at login too: a new session came up without a bar (the login LaunchAgent
  only starts skyland, and launchd kills what a LaunchAgent leaves running). skyland
  starts either way.

**Safety**
- skyland quits at once when its Accessibility permission is taken back while it runs:
  its active event taps (alt + mouse, arrow keys) froze every key and click until a
  forced reboot.

## v0.2.0

**Animations**
- Hyprland's animation system: `[animations] preset = 'hyprland' | 'slide' | 'gnome' |
  'vertical' | 'cyberspace'` (or several stacked, `['cyberspace', 'gnome']`: the later
  one replaces the nodes it sets), and `bezier` / `animation` lines pasted from a hyprland.conf
  (tree with inheritance, named curves, `slide`, `slidevert`, `popin`, `gnomed`, `fade`,
  `slidefade`, and skyland's `cyberspace` that rezzes windows in through a white-hot scan
  line). Window open, close, move, workspace and scratchpad switches play as tracks in
  the Dock payload; the older keys keep skyland's look. Preset choice in the settings
  window. Needs the payload (`skyland sa build`, `killall Dock; skyland sa load`).

**Liquid Glass**
- `[decoration] ui-style = 'metal' | 'glass'` (also in the settings window): skyland's
  panels (overview, window switcher, mode and on / off HUDs, settings window, wallpaper
  picker, media widget) in Liquid Glass, the engine of skylandbar: Apple's glass on macOS
  26, a refraction shader with Screen Recording, Core Animation's backdrop otherwise.
  `metal` keeps the theme tinted blur.

**Bar height**
- `bar-height <px>|default` command: a bar (SkylandBar, sketchybar) sends its own height
  over the socket and the windows are laid out below it, over the config's `bar-height`
  (`default` goes back to it, no argument prints the height in use). The hypr profile's
  sketchybar sends it at every load.

**Border**
- The animated border hides while a window is dragged or resized with the mouse (title
  bar, edges, or the mouse modifier) instead of lagging behind it, and comes back at
  mouse up.

**Binding modes**
- `mode-indicator = 'hud' | 'bar' | 'off'`: a mode other than `main` (Hyprland submap)
  shows its name and keys in a HUD, or in the `skyland.mode` sketchybar item with a
  `skyland_mode` event (`MODE=<name>`). Example `resize` mode on `alt-shift-r` in the hypr
  profile.

**Window switcher**
- `switcher [next|prev] [--workspace focused|all]` (`alt-backtick`): windows of every
  workspace, most recently focused first, with live thumbnails (app icons without Screen
  Recording). Held like `cmd-tab`, releasing the modifier focuses the selection;
  `switcher` alone stays open and filters as you type. Thumbnails freed on close.

**Window rules**
- `window-rule` command, Hyprland's windowrule v2 for `on-window-detected`: `size` /
  `move` (points or % of the screen), `center`, `opacity <active> [<inactive>]`,
  `rounding`, `noborder`, `nodim`, `noanim` per window. Editable in the Rules tab
  ("More").

**Shadows**
- `[decoration] shadow = 'on' | 'off' | 'floating'`: macOS window shadows off, or only on
  floating windows (Hyprland `decoration:shadow`); each window gets its own shadow back
  when skyland is turned off or quits. Needs the payload (`skyland sa build`, then
  `killall Dock; skyland sa load`).

**Smart gaps, workspace rules**
- `smart-gaps` / `smart-border`: a workspace's single tiled window fills the screen
  below the bar, without border nor rounded corners (Hyprland `w[tv1]` rules, formerly
  `no_gaps_when_only`); switches in the settings window.
- `[workspace-rules.<name>]`: `gaps.outer`, `gaps.inner` and `layout = 'master' | 'dwindle'`
  per workspace.


**Pin**
- New `pin [on|off|toggle]` command (Hyprland `pin`, `alt-ctrl-p`): a floating window
  stays on screen at the same place on every workspace of its monitor (picture in
  picture, a call, a timer), remembered across restarts, `%{window-is-pinned}`.



**Trackpad**
- `[gestures] workspace-swipe`: a 3 (or 4) finger swipe switches the screen under the
  cursor to the previous / next workspace (Hyprland `workspace_swipe`), with distance,
  threshold, direction and invert options, a Trackpad section in the settings window,
  and a `skyland doctor` check for the macOS gesture using as many fingers.
- The windows follow the fingers: the current workspace's tiles slide with the swipe and
  the next one's come in from the edge; let go past the threshold and the switch goes
  on from there, before it they spring back (rubber band past the last workspace).

**Scratchpads**
- New `scratchpad toggle [name] [--app <bundle id>] | move [name]` command: the
  scratchpad windows slide in from the top, floating and centered, and slide back up;
  done inside skyland (a toggle took 6 to 10 CLI processes, an app start polled the CLI
  up to 40 times). `skyland scratch …` still works. **Your config**: bind
  `alt-s = 'scratchpad toggle'` instead of `exec-and-forget skyland scratch toggle`
  (same for `move` and named ones) to skip the process.

**Performance**
- Skyland.app and the `aerospace` CLI are built in release mode (they shipped as
  debug builds): half the CPU for a workspace switch, faster CLI queries (sketchybar,
  scripts). The CLI moves to `.build/aerospace`; `bin/skyland-build --debug` for
  development.
- Input: alt + drag no longer runs a refresh per mouse event (one at the drop),
  focus follows mouse does nothing while the cursor stays over the focused window,
  and the key / mouse taps run on their own thread, so typing and clicking in other
  apps never wait for skyland.
- sketchybar: skyland pushes the workspaces and the window title itself, with one
  `sketchybar` call when they change, instead of a script with ~20 processes and 4
  CLI calls on up to 3 events per change. CLI queries (`list-*`, `config`, `echo`)
  no longer run a refresh session. **Your config**: drop
  `exec-and-forget sketchybar --trigger skyland_update` from `on-focus-changed` and
  the `exec-on-workspace-change` line (they still work, but cost for nothing).
- Animations: the Dock payload steps every running animation (slides, fades, dim)
  in one loop synced to the display, and applies each frame of all windows in one
  SkyLight transaction: the windows of a workspace switch move together, without
  judder, and one thread instead of one per window. Several payload commands go in
  one connection. Needs `skyland sa build` then `killall Dock; skyland sa load`.
- Idle: skyland no longer polls the window list all day (the menu bar check runs
  only while the cursor is near the top of a screen, the system prompt check on app
  activation and once a second), reads the theme once per change, and decorates
  once per command: about 0.2% CPU at rest instead of 0.7%.
- Media widget: no work while nothing plays (the 30 fps timer stops once the wave
  is flat, and while the widget is hidden), the now playing check backs off to 15 s
  when paused, the artwork is decoded once per track, and the audio analysis no
  longer wakes the main thread ~100 times a second.
- Media widget `audioware`: the wave is drawn with Metal on the GPU (blur too) instead
  of Core Graphics bitmaps: about 9% CPU while playing instead of 21%, the same look.

## v0.1.9

**Performance**
- Media widget `audioware` style: about 26% CPU instead of 38% while playing (each
  plane of the wave drawn into its own bitmap, the blurred planes repaint at 15 fps,
  the wave shape is capped at 260 points).

## v0.1.8

**Media widget**
- New **`audioware`** style (`[media] style = 'audioware'`): a light wave after the
  Audioware cover art, driven by the audio (flat when silent, the center line is the
  progress), in the theme's colors, live.
- Fixes: play / pause and a new track or video are always picked up (the now playing
  stream could go silent), a non-square artwork (video thumbnail) fills its square
  instead of showing grey bands, leftover background helpers are cleaned up.

**cyberdeck**
- `alt-shift-d` opens the [skyland-cyberdeck](https://github.com/waxdred/skyland-cyberdeck)
  HUD (clock, calendar, connections, system, herdr agents), needs skyland-cyberdeck 0.2.0.

## v0.1.7

**Performance**
- **Memory**: skyland uses about 42 MB instead of 137 MB with the rotating border on
  (its gradient is computed at a quarter of the resolution, the stroke stays sharp), and
  the workspace overview frees its thumbnails and full-screen panel when it closes
  instead of keeping them all day (stable around 76 MB after using it).

## v0.1.6

**Fixes**
- **alt + mouse** works again on the focused window with the rotating border on (the
  border window was taken for the window under the cursor).

**Docs**
- New README demo: rotating border, dim inactive, alt + mouse.

## v0.1.5

**Hyprland**
- **Dim inactive windows** (`[decoration] dim-inactive`, percent, also in the settings
  window): unfocused windows are darkened, fading with focus. Needs the Dock payload
  rebuilt (`skyland sa build && skyland sa load`).
- **Rotating border** (`[decoration] border-rotate-ms`, Hyprland `borderangle` loop): the
  focused window border gradient turns. skyland draws it itself, rotated by Core
  Animation (no measurable CPU); hidden while windows animate and in the overview.

**Install**
- `skyland sa load` offers to write the sudoers rule (payload injected at login without
  a password) and renews it after each rebuild of the payload.

**Docs**
- `CONTRIBUTING.md` for the fork.

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
