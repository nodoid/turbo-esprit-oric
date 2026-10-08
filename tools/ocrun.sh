#!/bin/sh
# Run a tape in Oricutron (Atmos + Microdisc = 64K) and screenshot it.
# usage: ocrun.sh file.tap seconds out.png      (OCDIR = Oricutron directory)
OCDIR=${OCDIR:-$HOME/Downloads/Oricutron_osx_v09}
TAP=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
pkill -x oricutron 2>/dev/null
cd "$OCDIR" && ./oricutron -R soft -m atmos -k microdisc --turbotape on -t "$TAP" >/tmp/oc.log 2>&1 &
sleep "${2:-10}"
if [ -n "$3" ]; then
  W=$(osascript -e 'tell application "System Events" to tell process "oricutron" to get {position, size} of window 1' 2>/dev/null | tr -d ' ')
  X=$(echo $W|cut -d, -f1); Y=$(echo $W|cut -d, -f2); WW=$(echo $W|cut -d, -f3); H=$(echo $W|cut -d, -f4)
  screencapture -x -R$X,$Y,$WW,$H "$3"
fi
