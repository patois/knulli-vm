#!/bin/bash
# In-guest: put REAL signal onto a capture device GrainBrick is recording, so
# the app's record path can be exercised without a physical microphone.
#
#   usage: audio_feed.sh <usb|mic> [--tone] [--wav FILE] [--secs N] [--sub N]
#                        [--wait N] [--probe]
#          (no --tone/--wav: raw S16_LE is read from stdin)
#   --probe: print "<rate> <channels> <sub>" for the capture stream and exit —
#            the host side (knulli-vm feed) sizes its encoder from this
#            BEFORE any bytes flow; on one shared ring buffer a rate mismatch
#            is a pitch shift, not an error.
#
# Which end of the loopback to write is NOT guesswork. Two measured facts about
# this kernel's snd-aloop drive the whole script:
#
#   1. The cable is CROSS-DEVICE, same substream: playback device 0 sub N feeds
#      capture device 1 sub N, and playback device 1 sub N feeds capture device
#      0 sub N. (Same-numbered pairs carry nothing at all. Verified by measuring
#      RMS across every pair — `arecord` returns full-length buffers of zeros
#      from a dead cable, so reading N bytes proves nothing, which is how the
#      cross-device map stayed "unproven" for a day.)
#   2. GrainBrick opens the capture side: plughw:CARD=USBAudio,DEV=0 for the
#      USB source, hw:0,0 for the built-in mic. Both are device 0, so the feed
#      goes to THIS card's playback device 1.
#
# The substream index is discovered, never hardcoded — same rule that caught the
# stale-XRUN ghost in audio_capture.sh: ALSA hands out the next free sub, so a
# leftover holder shifts the app's stream elsewhere and writing sub 0 then
# records silence that looks exactly like a broken app. If the app's capture
# stream is open we match its sub and its hw_params; only when nothing is
# recording yet do we fall back to sub 0 and the app's own preset format.
set -uo pipefail
SUDO=sudo
[ "$(id -u)" = 0 ] && SUDO=

TARGET="${1:?usage: audio_feed.sh <usb|mic> [flags]}"; shift
MODE=stdin WAV="" SECS=0 WANT_SUB="" PROBE=0 WAIT="${FEED_WAIT:-20}"
while [ $# -gt 0 ]; do
    case "$1" in
        --tone) MODE=tone; shift;;
        --wav)  MODE=wav; WAV="$2"; shift 2;;
        --secs) SECS="$2"; shift 2;;
        --sub)  WANT_SUB="$2"; shift 2;;
        --wait) WAIT="$2"; shift 2;;
        --probe) PROBE=1; shift;;
        *) echo "audio_feed: unknown flag $1" >&2; exit 2;;
    esac
done

case "$TARGET" in
    # The app's USB source: plughw:CARD=USBAudio,DEV=0, 48k/16/stereo.
    usb)   CARD_ID=USBAudio; CH=2;;
    # The app's BUILT-IN MIC preset: hw:0,0, 48k/16/mono (mono, not stereo).
    mic)   CARD_ID=Codec;    CH=1;;
    *) echo "audio_feed: target must be usb or mic" >&2; exit 2;;
esac
RATE=48000; FMT=S16_LE

NUM=""
for d in /proc/asound/card*/; do
    d=${d%/}
    [ "$(cat "$d/id" 2>/dev/null)" = "$CARD_ID" ] && { NUM=${d##*/card}; break; }
done
[ -n "$NUM" ] || { echo "audio_feed: no card with id $CARD_ID (run setup_audio.sh)" >&2; exit 1; }
CAP_DEV=0; PCM=/proc/asound/card"$NUM"/pcm"$CAP_DEV"c
[ -d "$PCM" ] || { echo "audio_feed: $PCM missing" >&2; exit 1; }

# --- find the capture substream the app is holding --------------------------
# State names come from the kernel's snd_pcm_state_name() — the vocabulary is
# OPEN/SETUP/PREPARED/RUNNING/XRUN/DRAINING/PAUSED/SUSPENDED/DISCONNECTED
# (an older revision of this script matched "OPENED", which does not exist, so
# a not-yet-started app stream was invisible to it and the feed landed blind).
# Precedence: RUNNING wins outright; PREPARED/SETUP/OPEN mean "the app has the
# stream, it is starving for exactly the data this script supplies"; XRUN is
# deliberately NOT accepted — that is the stale-ghost state that fooled
# audio_capture.sh once, and the motion test below can still pick a live one
# out from under it. An explicit --sub always wins: it is how you feed a
# device that is open but not yet started.
pick_sub() {
    [ -n "$WANT_SUB" ] && { echo "$WANT_SUB"; return; }
    local s st opened="" a b
    for s in "$PCM"/sub*; do
        [ -r "$s/status" ] || continue
        st=$(awk '/^state:/{print $2}' "$s/status" 2>/dev/null)
        [ "$st" = RUNNING ] && { echo "${s##*sub}"; return; }
        case "$st" in
            PREPARED|SETUP|OPEN) opened="${opened:+$opened }${s##*sub}";;
        esac
    done
    [ -n "$opened" ] && { echo "${opened%% *}"; return; }
    for s in "$PCM"/sub*; do
        [ -r "$s/status" ] || continue
        a=$(awk '/hw_ptr/{print $3}' "$s/status" 2>/dev/null); [ -n "$a" ] || continue
        sleep 0.2
        b=$(awk '/hw_ptr/{print $3}' "$s/status" 2>/dev/null)
        [ -n "$b" ] && [ "$b" != "$a" ] && { echo "${s##*sub}"; return; }
    done
    echo ""
}
SUB=""
# --probe is a one-shot question for the host side — one look, no waiting.
# Only the real feed waits for the app's stream to appear.
deadline=$(( $(date +%s) + $( [ "$PROBE" = 1 ] && echo 0 || echo "$WAIT" ) ))
while :; do
    SUB=$(pick_sub)
    { [ -n "$SUB" ] || [ "$(date +%s)" -ge "$deadline" ]; } && break
    sleep 0.5
done

hp() { awk -v k="$1" '$1==k{print $2}' "$PCM/sub${2:-$SUB}/hw_params" 2>/dev/null; }

if [ "$PROBE" = 1 ]; then
    # Host side asks BEFORE starting its encoder: match the app's live stream
    # if there is one, otherwise report the app's own preset format.
    if [ -n "$SUB" ]; then
        r=$(hp rate "$SUB"); c=$(hp channels "$SUB")
        [ -n "$r" ] && RATE=$r; [ -n "$c" ] && CH=$c
        echo "$RATE $CH $SUB"
    else
        echo "$RATE $CH -"
    fi
    exit 0
fi

[ -n "$SUB" ] || { SUB=0; echo "audio_feed: nothing is recording on card $NUM yet — feeding sub 0 blind" >&2; }
PLAY_DEV=$(( 1 - CAP_DEV ))     # cross-device cable, see header

# Match whatever the app asked the hardware for, so the two ends agree.
r=$(hp rate); c=$(hp channels); f=$(hp format)
[ -n "$r" ] && RATE=$r
[ -n "$c" ] && CH=$c
[ -n "$f" ] && FMT=$f
echo "audio_feed: $TARGET -> card $NUM ($CARD_ID) capture dev$CAP_DEV sub$SUB ${RATE}Hz/$CH/$FMT; writing playback dev$PLAY_DEV sub$SUB"

DEST="hw:$CARD_ID,$PLAY_DEV,$SUB"
# WHAT -d ACTUALLY DOES — the comment here used to call it "the release valve",
# and measured, it is not. A loopback playback stream advances only while
# something reads the far end; point aplay at a cable nobody is capturing and it
# blocks INSIDE write(), and since the duration is counted in frames WRITTEN,
# the counter never advances either (`--secs 2` did not end a stream that had
# been blocked for minutes). What really happens is more useful than what was
# claimed: the feed parks, holding the substream, and flows the instant the app
# opens the capture end. That is why the documented order is "start the feed,
# THEN press record" — the parked feed is waiting for you, it is not a hang.
# Cleaning up a feed nobody wanted is `knulli-vm feed stop` (and cmd_stop's
# sweep), never a duration that can't be reached.
DUR=()
[ "$SECS" -gt 0 ] && DUR=(-d "$SECS")
play() { $SUDO aplay -D "$DEST" -f "$FMT" -r "$RATE" -c "$CH" -t raw -q -B 100000 -F 25000 "${DUR[@]}"; }

# A loud swept tone with a slow amplitude wobble: unmistakable on a scope, on
# the app's live waveform, and in a recorded file's RMS.
tone() {
    while :; do
        python3 -I -c '
import math, sys, array, os
rate, ch, secs = '"$RATE"', '"$CH"', 2
n = rate*secs
a = array.array("h", [0]) * (n*ch)
for i in range(n):
    t = i/rate
    f = 220 + 660*(0.5 - 0.5*math.cos(2*math.pi*t/2.0))      # 220..880 sweep
    v = 0.45*(0.6 + 0.4*math.sin(2*math.pi*t/0.37))           # wobble
    s = int(32767*v*math.sin(2*math.pi*f*t))
    for k in range(ch): a[i*ch+k] = s
try:
    sys.stdout.buffer.write(a.tobytes())
except BrokenPipeError:
    os._exit(0)      # aplay finished (--secs) — ending the loop is normal, not a crash;
                     # os._exit, not sys.exit: shutdown would flush the broken pipe again
'
    done
}

# Decode + channel-match a WAV with the stdlib only (no ffmpeg on this image).
wav_to_raw() {
    python3 -I -c '
import sys, wave, array, os
src, rate, ch = "'"$WAV"'", '"$RATE"', '"$CH"'
w = wave.open(src)
if w.getframerate() != rate:
    sys.exit(f"audio_feed: {src} is {w.getframerate()} Hz, the capture needs {rate} Hz — convert it first")
if w.getsampwidth() != 2:
    sys.exit(f"audio_feed: {src} is {w.getsampwidth()*8}-bit, the capture needs 16-bit")
sc = w.getnchannels()
d = array.array("h"); d.frombytes(w.readframes(w.getnframes()))
out = array.array("h", [0]) * ((len(d)//sc)*ch)
for i in range(len(out)//ch):
    if sc == 1:  v = d[i]
    else:        v = sum(d[i*sc+k] for k in range(sc))//sc   # downmix to mono
    for k in range(ch): out[i*ch+k] = v
try:
    sys.stdout.buffer.write(out.tobytes())
except BrokenPipeError:
    os._exit(0)
'
}

case "$MODE" in
    tone) tone | play;;
    # aplay understands WAV itself, but only if the file already matches the
    # capture's channels — so convert first and keep one raw path.
    wav)  wav_to_raw | play;;
    stdin) cat | play;;
esac
