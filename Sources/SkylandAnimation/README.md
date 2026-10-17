# SkylandAnimation

Hyprland's animation system for skyland, as a module to wire into the window manager
later (see [Attaching it to skyland](#attaching-it-to-skyland)). It turns a window event
(open, close, move, workspace or scratchpad switch) into a **track**: the window's rect,
opacity and brightness sampled over the animation, which the Dock payload plays at the
display rate (`osax/payload.m`, `track` command). Every style comes down to samples, so a
new style never needs a new payload.

- Foundation only, no AppKit (except `CyberspaceOverlay`, macOS only), unit tested in
  `Sources/SkylandAnimationTests`
- the config is Hyprland's: `bezier` and `animation` lines, pasted from a hyprland.conf
- `skyland-anim` plays any style on a real window right now
- `tools/animation-lab/index.html` plays them in a browser (a JS port of this module, same
  numbers)

## Styles

Hyprland's four style families, plus skyland's own:

| style | coming in | leaving |
|---|---|---|
| `slide [top\|bottom\|left\|right]`, `slidevert` | a window comes in by a screen edge (the closest one without another screen behind it); a workspace slides sideways (`slide`) or vertically (`slidevert`), the next one from the right / from below | out by the same edge, or the other way |
| `popin [N%]` | from N% of its size around its center (default 80%) | back to N% |
| `gnomed` | unfolds from a line across its middle, GNOME-like | folds back to the line |
| `slidefade [N%]`, `slidefadevert [N%]`, `fade` | glides N% of the screen while it fades in (default 20%); `fade` does not move | glides on while it fades out |
| `cyberspace` | rezzes: ignites as a white-hot scan line, unfolds through glitches (one-frame tears, opacity dips, flashes), settles while the glow cools; on a workspace switch it streaks along the switch and waits for the old windows to derez | derezzes: glitch burst, collapse to a glowing line, shrink to a dot that fades |

Every style works for every event (Hyprland keeps `popin` / `gnomed` to windows and
`slidevert` / `slidefade` to workspaces). The glitches are random but the same for a
window and an event. With `cyberspace`, skyland also draws a neon frame in the theme
accent around the window (`CyberspaceOverlay`): the payload can only whiten or darken a
window, not color it.

A full slide of a workspace switch through a screen edge shared with another screen
becomes `slidefade 20%`: the window server draws a moving window wherever it is, so it
would show on the other screen (Hyprland draws each monitor on its own).

## Config

The same lines as hyprland.conf, without `bezier =` / `animation =`:

```toml
[animations]
bezier = [
  'overshot, 0.05, 0.9, 0.1, 1.05',
]
animation = [
  'windows, 1, 5, overshot, slide',          # NAME, ONOFF, SPEED (ds: 5 = 500 ms), CURVE [, STYLE]
  'windowsOut, 1, 4, default, popin 80%',
  'fade, 1, 3, default',
  'workspaces, 1, 6, default, slidefade 20%',
  'specialWorkspace, 1, 5, overshot, slidevert',
]
```

```swift
let (settings, diagnostics) = AnimationSettings.parse(bezier: bezierLines, animation: animationLines)
let (fromHyprland, _) = AnimationSettings.parse(hyprlandConf: try String(contentsOf: hyprlandConfUrl))
```

- the tree and inheritance are Hyprland's: a node without its own line takes its parent's
  whole line, up to `global` (built in: on, 8 ds, `default`); `NAME, 0` turns a node off
- built-in curves: `default` (0, 0.75, 0.15, 1) and `linear`
- nodes that mean nothing on macOS (`fadeShadow`, `fadePopups*`, `fadeDpms`, `zoomFactor`,
  `monitorAdded`) load and are reported as notices, so a pasted block works
- which node plays: open `windowsIn` (+ `fadeIn` for the opacity), close `windowsOut`
  (+ `fadeOut`), move `windowsMove`, workspace switch `workspacesIn` / `workspacesOut`,
  scratchpad `specialWorkspaceIn` / `specialWorkspaceOut`
- default styles: `popin 80%` for windows, `slide` for workspaces, `slidevert` for
  scratchpads

### Presets

`AnimationPreset.all`, each a set of lines:

| preset | look |
|---|---|
| `hyprland` | Hyprland's own default config: windows pop in from 87%, workspaces fade |
| `slide` | windows slide in by the closest screen edge, workspaces slide sideways |
| `gnome` | windows unfold from a line (gnomed), workspaces glide and fade (slidefade 20%) |
| `vertical` | skyland's look so far: windows pop in from 80%, workspaces slide vertically |
| `cyberspace` | windows rez in from a white-hot scan line through glitches, and derez out |

## Tracks and the payload

```swift
let animator = WindowAnimator(settings: settings)
let context = WindowContext(windowId: id, rect: tile, monitor: screen, direction: +1,
                            opacity: 0.9, brightness: 0, neighbourEdges: screen.neighbourEdges(among: screens))
if let track = animator.track(for: .workspaceIn, context) {
    skylandSa(track.payloadCommand)   // track <wid> <ms> <mode> <channels> <n> (x y w h alpha brightness) * n
}
```

- rects are screen points, top-left origin (AeroSpace's `Rect`, SkyLight's bounds)
- `rect` is where the window ends (coming in) or where it is (leaving); `direction` is +1
  towards a higher workspace, -1 towards a lower one; for a scratchpad, the side it comes
  from and goes back to (-1: the top, skyland's)
- 60 samples per second (90 for cyberspace), at most 240 per track; the payload
  interpolates linearly between them at the display rate, in its display-synced loop
- modes: `enter` (mapped onto the window's real frame through the last rect, so an app
  applying a slightly different frame is followed), `leave` (screen rects, back to the
  real frame at the end: the window was hidden), `hold` (stays at the last rect: closing)
- channels: frame, alpha, brightness (-1 black .. 1 white); a later `fade` / `alpha`,
  `dim`, `animate` / `untransform` on the window takes its channel over
- `osax/test/payload_test.c` tests the payload side without macOS (stand-in SDK headers,
  recorded SkyLight calls, a fake clock); `skyland sa build` runs it

## Trying it now

```sh
skyland sa build && skyland sa load          # a payload with `track` (ping says "... track")
swift build --product skyland-anim
.build/debug/skyland-anim cyberspace         # the frontmost window rezzes in
.build/debug/skyland-anim cyberspace out     # derezzes as if its workspace was switched away
.build/debug/skyland-anim popin 87% close    # nothing is closed: it comes back after
.build/debug/skyland-anim slide in --dir -1
.build/debug/skyland-anim --preset gnome open
.build/debug/skyland-anim list
```

Or open `tools/animation-lab/index.html` in a browser: a simulated skyland desktop that
plays every style and preset, with slow motion and the track it would send.

## Attaching it to skyland

Not wired yet. The plan (issue #33):

1. `Package.swift`: AppBundle depends on `SkylandAnimation`.
2. Config: `[animations] bezier = [...]`, `animation = [...]` (and `preset = '...'`)
   parsed with `AnimationSettings.parse`; the current keys map onto nodes:
   `windows-ms` / `windows-bezier` to `windows`, `workspaces-*` to `workspaces` with
   `slidevert`, `fade-*` to `fade`.
3. `Sources/AppBundle/skyland/animation.swift`: each `skylandSa("animate ...")` becomes
   `animator.track(for:_:)` + `track.payloadCommand`:
   - `animateLayoutChange`: a window never laid out: `.open`; unhidden after a workspace
     switch: `.workspaceIn` (direction from `slideSign`); moved: `.move(from:)`
   - `animateSlideOut`: `.workspaceOut`
   - `animateClose`: `.close` (wait `track.durationMs` before closing)
   - `scratchpad.swift` show / hide: `.specialIn` / `.specialOut` with direction -1
4. `decoration.swift`: no `fade` / `dim` for a window whose track drives its alpha /
   brightness (`track.channels`), else it takes the channel over.
5. `pauseAnimatedBorder(ms: track.durationMs)`, and `CyberspaceOverlay.play` for the
   cyberspace style, with the theme accent.
6. Settings window: an Animations tree (node, on / off, speed, curve, style).
