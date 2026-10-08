#!/bin/sh
# Boot a disk image in Oricutron (Atmos + Microdisc) and screenshot it.
# usage: ocdisk.sh file.dsk seconds out.png   (OCDIR = Oricutron directory)
OCDIR=${OCDIR:-$HOME/Downloads/Oricutron_osx_v09}
DSK=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
pkill -x oricutron 2>/dev/null
sleep 0.5
cd "$OCDIR" && ./oricutron -R soft -m atmos -k microdisc -d "$DSK" >/tmp/oc.log 2>&1 &
sleep "${2:-10}"
if [ -n "$3" ]; then
  W=$(osascript -e 'tell application "System Events" to tell process "oricutron" to get {position, size} of window 1' 2>/dev/null | tr -d ' ')
  X=$(echo $W|cut -d, -f1); Y=$(echo $W|cut -d, -f2); WW=$(echo $W|cut -d, -f3); H=$(echo $W|cut -d, -f4)
  screencapture -x -R$X,$Y,$WW,$((H-260)) "$3"
fi
