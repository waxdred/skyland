#!/usr/bin/env bash
# sketchybar plugin: show the existing skyland workspaces (persistent, non empty,
# focused), highlight the focused one, and set the focused window title.
# usage: update.sh <path to the skyland CLI>
CLI="$1"
# Catppuccin like the work bar, unless skyland-theme wrote theme colors
TEXT_DIM=0xffa5adcb ACCENT=0xffc6a0f6 ITEM_BG=0xff363a4f ITEM_BG_ACTIVE=0xff5b6078 BORDER=0xff5b6078 BORDER_ACTIVE=0xffc6a0f6
# shellcheck source=/dev/null
[[ -r "$HOME/.cache/skyland/theme.env" ]] && source "$HOME/.cache/skyland/theme.env"

existing=" $("$CLI" list-workspaces --monitor all 2>/dev/null | tr '\n' ' ') "
# each workspace on the bar of its screen ("<workspace> <screen>" lines)
screens="$("$CLI" list-workspaces --monitor all --format '%{workspace} %{monitor-appkit-nsscreen-screens-id}' 2>/dev/null)"
focused="$("$CLI" list-workspaces --focused 2>/dev/null)"
[[ -n "$focused" ]] || exit 0 # skyland not running

args=()
for i in $(seq 1 12); do
    screen="$(awk -v w="$i" '$1 == w { print $2 }' <<<"$screens")"
    args+=(--set "workspace.$i" display="${screen:-active}")
    if [[ "$i" == "$focused" ]]; then
        args+=(--set "workspace.$i" drawing=on icon.color=$ACCENT background.color=$ITEM_BG_ACTIVE background.border_color=$BORDER_ACTIVE)
    elif [[ "$existing" == *" $i "* ]]; then
        args+=(--set "workspace.$i" drawing=on icon.color=$TEXT_DIM background.color=$ITEM_BG background.border_color=$BORDER)
    else
        args+=(--set "workspace.$i" drawing=off)
    fi
done

# Same format as the work plugins/window_title.sh
IFS='|' read -r app title < <("$CLI" list-windows --focused --format '%{app-name}|%{window-title}' 2>/dev/null)
if [[ -z "$title" ]]; then
    label="Desktop"
else
    (( ${#title} > 40 )) && title="${title:0:37}..."
    label="${app:+$app: }$title"
fi
args+=(--set window_title label="$label")

sketchybar "${args[@]}"
