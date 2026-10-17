#!/usr/bin/env bash
# Turn your sketchybar (its space.* items for macOS Spaces) into a skyland bar: run
# at the end of the sketchybarrc when ~/.config/.skyland-profile is hypr (every
# load, also a sketchybar restart), and by `skyland-env` after `sketchybar --reload`.
# Replaces the space.* items by skyland workspaces 1-12 and points window_title
# at skyland.
# skyland pushes the updates itself (Sources/AppBundle/skyland/bar.swift); update.sh
# runs on skyland_update (skyland-theme apply, this script).
set -euo pipefail
DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
UPDATE="$DIR/update.sh"
CLI="$(cd "$DIR/../../.." && pwd)/.build/aerospace"

# Same icons and Catppuccin colors as the sketchybarrc / plugins/space.sh
ICONS=("󰇧" "󰭻" "󰩃" "󰚩" "" "󰝚" "󰉋" "󰆼" "" "󰘙" "󰀵" "󰆺")
SUBTEXT0=0xffa5adcb
MAUVE=0xffc6a0f6
SURFACE0=0xff363a4f
SURFACE2=0xff5b6078

# idempotent (runs from the sketchybarrc and from skyland-env): the
# space regex also matches the workspace.N items of a previous run
# topmost=on: above the auto-hidden macOS menu bar, which else slides in over the
# bar on hover and takes the clicks meant for the workspace icons
args=(--bar topmost=on --remove '/space\..*/' --remove skyland --add event skyland_update)
# optional items of your sketchybarrc: workspaces go before `space_separator` (else
# at the end of the left side), the focused window title goes to `window_title`
move=()
for i in $(seq 1 12); do
    sketchybar --query space_separator >/dev/null 2>&1 && move=(--move "workspace.$i" before space_separator)
    # after space_separator's left neighbour: insert before the separator
    args+=(--add item "workspace.$i" left
        --set "workspace.$i" icon="${ICONS[$((i - 1))]}"
            icon.font="Hack Nerd Font:Bold:16.0"
            icon.color=$SUBTEXT0
            icon.padding_left=8
            icon.padding_right=8
            background.color=$SURFACE0
            background.border_color=$SURFACE2
            background.border_width=1
            background.corner_radius=8
            background.height=26
            label.drawing=off
            drawing=off
            click_script="$CLI workspace $i"
        "${move[@]}")
done
# skyland's icon (resources/Skyland.icns) on the left: replaces the Apple logo
# item of your sketchybarrc if it has one (its click is kept), else a new item
logo=(icon.drawing=off background.image=app.com.waxdred.skyland background.image.scale=0.8
    background.image.drawing=on background.color=0x00000000 width=36)
if sketchybar --query apple >/dev/null 2>&1; then
    args+=(--set apple "${logo[@]}")
else
    args+=(--remove skyland.logo --add item skyland.logo left --set skyland.logo "${logo[@]}"
        click_script="$CLI settings" --move skyland.logo before workspace.1)
fi
# One hidden item runs the update for all workspaces and the window title
args+=(--add item skyland left
    --set skyland drawing=off updates=on script="$UPDATE $CLI"
    --subscribe skyland skyland_update)
# the title comes from skyland: no script of its own (it ran on front_app_switched)
sketchybar --query window_title >/dev/null 2>&1 && args+=(--set window_title script="" update_freq=0)
sketchybar "${args[@]}"
# recolors the whole bar with the current [theme] file, then triggers skyland_update
"$DIR/../../../bin/skyland-theme" apply || sketchybar --trigger skyland_update
