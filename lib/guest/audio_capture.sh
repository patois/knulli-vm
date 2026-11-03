#!/bin/bash
# In-guest: capture the aloop cable that actually CARRIES the app's audio,
# for piping to the Mac.
#
# snd-aloop hands out one substream per opened stream: every playback stream
# (the app's own, an aplay it spawns, the UI's preview stream) takes the next
# free subN, and cable N routes playback subN -> capture subN. Capturing a
# hardcoded `hw:Loopback,1,0` therefore silently lies whenever anything stale
# holds sub0: on 2026-11-02 an app instance that `knulli-vm stop` had
# orphaned occupied sub0 in XRUN state, the live app's aplay landed on sub3,
# and the Mac heard the dead sub0's zeros forever — indistinguishable from
# "the app outputs silence" and a multi-hour wild goose chase through the
# app's DSP chain.
#
# So never guess the sub — and never assume WHO owns it. GrainBrick <= 1.0
# pumps its output through a child `aplay`; GrainBrick 1.0.1 writes ALSA
# itself and never spawns one, so an aplay-only search found nothing on a
# fresh install: the capture gave up after 90 s, the Mac heard silence, and
# nothing drained the loopback, so the app sat underrunning (which also costs
# input responsiveness). The ground truth is MOTION: the cable to capture is
# the playback sub whose hw_ptr ADVANCES. An aplay owner still wins when one
# exists (that sub is the app's main output by construction); otherwise the
# advancing sub is it. A sub that merely reads "state: RUNNING" without
# moving is exactly the stale-XRUN case above, so it never qualifies.
#
# runs as root (guest user is not in the audio group); execs arecord, so
# pkill patterns matching "arecord -D hw:Loopback" still stop the pipe.
set -u
CARD=$(awk '/Loopback/{print $1; exit}' /proc/asound/cards)
[ -n "$CARD" ] || { echo "audio_capture: no Loopback sound card (run setup_audio.sh)" >&2; exit 1; }
PCM=/proc/asound/card"$CARD"/pcm0p

hw_ptr() { awk '/hw_ptr/{print $3}' "$1" 2>/dev/null; }
owner_of() { awk '/owner_pid/{print $3}' "$PCM/sub$1/status" 2>/dev/null; }

# playback sub indices whose hw_ptr moves between two samples. The 0.25 s gap
# is far longer than one 25 ms period, so a live stream always shows motion
# and a stuck/XRUN one never does.
advancing() {
    local s a b
    for s in "$PCM"/sub*; do
        [ -r "$s/status" ] || continue
        a=$(hw_ptr "$s/status"); [ -n "$a" ] || continue
        sleep 0.25
        b=$(hw_ptr "$s/status")
        [ -n "$b" ] && [ "$b" != "$a" ] && echo "${s##*sub}"
    done
}

deadline=$(( $(date +%s) + ${AUDIO_WAIT:-90} ))
first_cand=0
sub="" why=""
while :; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "audio_capture: no app audio on the loopback card within ${AUDIO_WAIT:-90}s" >&2
        # dump what the card IS doing — 'the app is silent' and 'the app has
        # no stream at all' look identical from the Mac, so say which it is
        for s in "$PCM"/sub*; do
            [ -r "$s/status" ] || continue
            echo "  ${s##*sub}: $(grep -h -E 'state:|owner_pid|hw_ptr' "$s/status" | tr -s ' ' | tr '\n' ' ')" >&2
        done
        exit 1
    fi
    cands=$(advancing)
    if [ -n "$cands" ]; then
        [ "$first_cand" = 0 ] && first_cand=$(date +%s)
        # 1. an aplay owner wins outright. For apps that pump through a child
        #    aplay (GrainBrick <= 1.0) that sub IS the main output, while a
        #    lower sub may be the UI's idle preview stream — which starts
        #    first and would otherwise be captured forever (zeros). Newest
        #    aplay first (sort -n -r): a stale one, if it lingers, sits on a
        #    dead sub and the live app's has the higher pid.
        for p in $(pgrep -x aplay 2>/dev/null | sort -rn); do
            for c in $cands; do
                [ "$(owner_of "$c")" = "$p" ] || continue
                sub=$c; why="aplay pid $p owns it"; break 2
            done
        done
        # 2. no aplay: wait APLAY_GRACE seconds after the first live stream
        #    for one to appear before concluding the app writes ALSA itself
        #    (GrainBrick 1.0.1 does, and never forks aplay). Without the
        #    grace the preview stream above would win this race too.
        if [ -z "$sub" ] && \
           [ $(( $(date +%s) - first_cand )) -ge ${APLAY_GRACE:-6} ]; then
            # highest sub index: a lower one is more likely a leftover
            sub=$(echo "$cands" | tail -1)
            why="pid $(owner_of "$sub") owns it (no aplay — the app writes ALSA itself)"
        fi
        if [ -n "$sub" ]; then
            echo "audio_capture: capturing playback sub $sub ($why) -> capture sub $sub" >&2
            echo "audio_capture: subs with moving audio: $(echo "$cands" | tr '\n' ' ')" >&2
            break
        fi
    fi
    sleep 0.5
done

# playback device 0 pairs with capture device 1 (empirical cable map, see
# setup_audio.sh); the subdevice index carries over 1:1.
exec arecord -D "hw:Loopback,1,$sub" -f S16_LE -r 48000 -c 2 -t raw -q \
    -B 100000 -F 25000
