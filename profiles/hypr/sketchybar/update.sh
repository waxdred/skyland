#!/usr/bin/env bash
# sketchybar plugin: show the existing skyland workspaces (persistent, non empty,
# focused), highlight the focused one, and set the focused window title.
# usage: update.sh <path to the skyland CLI>
CLI="$1"
SUBTEXT0=0xffa5adcb
MAUVE=0xffc6a0f6
SURFACE0=0xff363a4f
SURFACE2=0xff5b6078

existing=" $("$CLI" list-workspaces --monitor all 2>/dev/null | tr '\n' ' ') "
focused="$("$CLI" list-workspaces --focused 2>/dev/null)"
[[ -n "$focused" ]] || exit 0 # skyland not running

args=()
for i in $(seq 1 10); do
    if [[ "$i" == "$focused" ]]; then
        args+=(--set "workspace.$i" drawing=on icon.color=$MAUVE background.color=$SURFACE2 background.border_color=$MAUVE)
    elif [[ "$existing" == *" $i "* ]]; then
        args+=(--set "workspace.$i" drawing=on icon.color=$SUBTEXT0 background.color=$SURFACE0 background.border_color=$SURFACE2)
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
