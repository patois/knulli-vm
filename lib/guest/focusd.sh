#!/bin/bash
# Keep X input focus on the app window. The VM display has no window
# manager, so X focus sits on None and ALL synthesized key input — xdotool
# and the VNC keyboard alike (both go through XTEST) — is silently dropped.
# The app window is picked generically as the largest visible top-level
# (SDL names WM_CLASS after argv[0], so class-based search won't do).
export DISPLAY=:1
while true; do
    best=""; bestarea=0
    for w in $(xdotool search --maxdepth 1 --all --onlyvisible "" 2>/dev/null); do
        read -r W H < <(xdotool getwindowgeometry "$w" 2>/dev/null \
                        | sed -n 's/.* \([0-9]\+\)x\([0-9]\+\).*/\1 \2/p')
        [ -z "${W:-}" ] && continue
        area=$(( W * H ))
        [ "$area" -gt "$bestarea" ] && { bestarea=$area; best=$w; }
    done
    if [ -n "$best" ] && [ "$(xdotool getwindowfocus 2>/dev/null)" != "$best" ]; then
        xdotool windowfocus "$best" 2>/dev/null
        xdotool windowraise "$best" 2>/dev/null
    fi
    sleep 0.4
done
