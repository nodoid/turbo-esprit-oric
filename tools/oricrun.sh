#!/bin/sh
# Reset Oric.app, autoload a .tap and optionally screenshot the window after N seconds.
# usage: oricrun.sh file.tap [seconds out.png]
APP="$HOME/Downloads/Oric v1.8.3/Oric.app"
osascript -e 'tell application "Oric" to activate' -e 'delay 1' \
  -e 'tell application "System Events" to tell process "Oric" to click menu item "Reset" of menu 1 of menu bar item "File" of menu bar 1' >/dev/null
sleep 4
open -a "$APP" "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
if [ -n "$2" ]; then
  sleep "$2"
  B=$(osascript -e 'tell application "System Events" to tell process "Oric" to get {position, size} of window 1' | tr -d ' ')
  X=$(echo $B | cut -d, -f1); Y=$(echo $B | cut -d, -f2); W=$(echo $B | cut -d, -f3); H=$(echo $B | cut -d, -f4)
  screencapture -x -R$X,$Y,$W,$H "$3"
fi
