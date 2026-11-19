#!/bin/bash
set -euo pipefail

resources="$(cd "$(dirname "$0")/.." && pwd -P)"
item=yapsketch

if [[ "${1:-}" == --refresh ]]; then
    recording=off
    interval=0
    if [[ "$("$resources/../MacOS/YapSketch" recording-state)" == recording ]]; then
        recording=on
        # A forced quit releases the lock without sending an event.
        interval=5
    fi
    exec sketchybar --set "$item" "label.highlight=$recording" "update_freq=$interval"
fi

script="$(printf '%q' "$resources/SketchyBar/yapsketch.sh")"
sketchybar --add event yapsketch_state com.yapsketch.recordingStateChanged \
           --add item "$item" right \
           --set "$item" "script=$script --refresh" updates=on \
                         icon= icon.drawing=on icon.width=20 icon.highlight=off \
                         icon.background.drawing=on icon.background.color=0x00000000 \
                         "icon.background.image=$resources/SketchyBar/status-mark.png" icon.background.image.scale=0.25 \
                         label=● label.drawing=on label.highlight=off 'label.font=Helvetica Neue:Bold:10.0' \
                         label.padding_left=3 label.color=0xff9ca3af label.highlight_color=0xffff453a "$@" \
           --subscribe "$item" yapsketch_state system_woke \
           --trigger yapsketch_state
