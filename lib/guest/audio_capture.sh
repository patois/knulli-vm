#!/bin/bash
# In-guest: capture the aloop cable the app's aplay ACTUALLY owns, for
# piping to the Mac.
#
# snd-aloop hands out one substream per opened stream: every aplay (and
# the app UI's own preview stream) takes the next free subN, and cable N
# routes playback subN -> capture subN. Capturing a hardcoded
# `hw:Loopback,1,0` therefore silently lies whenever anything stale holds
# sub0: on 2026-11-02 an app instance that `knulli-vm stop` had orphaned
# occupied sub0 in XRUN state, the live app's aplay landed on sub3, and
# the Mac heard the dead sub0's zeros forever — indistinguishable from
# "the app outputs silence" and a multi-hour wild goose chase through the
# app's DSP chain. Never guess the sub again: find the sub owned by a
# running aplay (the app spawns exactly one), and capture that one.
#
# runs as root (guest user is not in the audio group); execs arecord, so
# pkill patterns matching "arecord -D hw:Loopback" still stop the pipe.
set -u
CARD=$(awk '/Loopback/{print $1; exit}' /proc/asound/cards)
[ -n "$CARD" ] || { echo "audio_capture: no Loopback sound card (run setup_audio.sh)" >&2; exit 1; }

deadline=$(( $(date +%s) + ${AUDIO_WAIT:-90} ))
sub=""
while [ -z "$sub" ]; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "audio_capture: no live aplay playback stream appeared within ${AUDIO_WAIT:-90}s" >&2
        exit 1
    fi
    # newest aplay first (sort -n -r): if a stale instance's aplay ever
    # lingers, its sub is XRUN-ish and the live app's is the higher pid
    for p in $(pgrep -x aplay 2>/dev/null | sort -rn); do
        for s in /proc/asound/card"$CARD"/pcm0p/sub*; do
            owner=$(awk '/owner_pid/{print $3}' "$s/status" 2>/dev/null)
            [ "$owner" = "$p" ] || continue
            grep -q "state: RUNNING" "$s/status" || continue
            sub=${s##*sub}
            echo "audio_capture: aplay pid $p owns playback sub $sub -> capturing capture sub $sub" >&2
        done
    done
    [ -n "$sub" ] || sleep 0.5
done

# playback device 0 pairs with capture device 1 (empirical cable map, see
# setup_audio.sh); the subdevice index carries over 1:1.
exec arecord -D "hw:Loopback,1,$sub" -f S16_LE -r 48000 -c 2 -t raw -q \
    -B 100000 -F 25000
