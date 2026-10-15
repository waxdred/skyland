#!/usr/bin/env bash
# Turn the work sketchybar (yabai Spaces) into a skyland bar: run at the end of
# the work sketchybarrc when ~/.config/.skyland-profile is hypr (every load, also
# a sketchybar restart), and by `skyland-env hypr` after `sketchybar --reload`.
# Replaces the space.* items by skyland workspaces 1-12 and points window_title
# at skyland. `skyland-env work` reloads the work config, which undoes all this.
# Updates come from skyland: see on-focus-changed / exec-on-workspace-change in
# profiles/hypr/.config/aerospace/aerospace.toml.
set -euo pipefail
DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
UPDATE="$DIR/update.sh"
CLI="$(cd "$DIR/../../.." && pwd)/.build/debug/aerospace"

# Same icons and Catppuccin colors as the work sketchybarrc / plugins/space.sh
ICONS=("󰇧" "󰭻" "󰩃" "󰚩" "" "󰝚" "󰉋" "󰆼" "" "󰘙" "󰀵" "󰆺")
SUBTEXT0=0xffa5adcb
MAUVE=0xffc6a0f6
SURFACE0=0xff363a4f
SURFACE2=0xff5b6078

# idempotent (runs from the work sketchybarrc and from skyland-env hypr): the
# space regex also matches the workspace.N items of a previous run
args=(--remove '/space\..*/' --remove skyland --add event skyland_update)
for i in $(seq 1 12); do
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
        --move "workspace.$i" before space_separator)
done
# One hidden item runs the update for all workspaces and the window title
args+=(--add item skyland left
    --set skyland drawing=off updates=on script="$UPDATE $CLI"
    --subscribe skyland skyland_update front_app_switched
    --set window_title script="$UPDATE $CLI" update_freq=0)
sketchybar "${args[@]}"
# recolors the whole bar with the current [theme] file, then triggers skyland_update
"$DIR/../../../bin/skyland-theme" apply || sketchybar --trigger skyland_update
