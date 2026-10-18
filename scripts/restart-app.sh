#!/usr/bin/env bash
# Restarts YapSketch on the current build, unless a recording is in progress
# (or still processing): quitting then would cut it short.
set -euo pipefail
cd "$(dirname "$0")/.."
LOG="$HOME/Library/Logs/YapSketch/YapSketch.log"
# (Not running, e.g. force-quit mid-recording: nothing to cut short.)
if [[ -f "$LOG" ]] && pgrep -f "YapSketch.app/Contents/MacOS/YapSketch$" >/dev/null; then
    last_start=$(grep -n "recording started" "$LOG" | tail -1 | cut -d: -f1 || true)
    last_end=$(grep -nE "report ready|recording discarded|start failed" "$LOG" | tail -1 | cut -d: -f1 || true)
    if [[ -n "$last_start" && ( -z "$last_end" || "$last_start" -gt "$last_end" ) ]]; then
        # A recording the app running now didn't start (it was force-quit mid-recording)
        # isn't in progress.
        started_at=$(sed -n "${last_start}p" "$LOG" | cut -c1-19)
        pid=$(pgrep -f "YapSketch.app/Contents/MacOS/YapSketch$" | head -1)
        app_since=$(date -j -f "%a %b %d %T %Y" "$(ps -o lstart= -p "$pid" | xargs)" "+%Y-%m-%d %H:%M:%S")
        if [[ "$app_since" < "$started_at" ]]; then
            echo "YapSketch is recording or processing right now; not restarting."
            exit 1
        fi
    fi
fi
osascript -e 'tell application id "com.yapsketch.app" to quit' 2>/dev/null || true
for _ in $(seq 1 15); do pgrep -f "YapSketch.app/Contents/MacOS/YapSketch$" >/dev/null || break; sleep 1; done
sleep 1
open build/YapSketch.app
sleep 3
pid=$(pgrep -f "YapSketch.app/Contents/MacOS/YapSketch$" || true)
[[ -n "$pid" ]] && echo "YapSketch restarted at $(ps -o lstart= -p "$pid" | xargs) (build: $(stat -f %Sm build/YapSketch.app/Contents/MacOS/YapSketch))"
