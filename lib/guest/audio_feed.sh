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
FEED_FAST=""
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
    # FAST: the supervisor asks this many times a second, and the motion probe
    # below sleeps 0.2 s per substream (1.6 s over eight) — fine for a one-shot
    # discovery, far too slow to notice the app opening a stream. "Nothing is
    # open" is the complete answer in that case.
    [ -n "$FEED_FAST" ] && { echo ""; return; }
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
# been blocked for minutes).
#
# That is why a feed that just sits there holding a dead cable is a BUG and not
# a parked valve: aplay stopped consuming, so the ssh channel filled, so the
# Mac's capture blocked, and every byte it queued came out late — input-side
# delay that never comes back, and a cable writing to a sub the app is not
# holding, which reads as pure silence with the feed reporting "running". Both
# of those were reported by users as "recording does not work". See supervise().
DUR=()
[ "$SECS" -gt 0 ] && DUR=(-d "$SECS")
play() { $SUDO aplay -D "hw:$CARD_ID,$PLAY_DEV,$1" -f "$FMT" -r "$RATE" -c "$CH" -t raw -q \
                   -B 100000 -F 25000 "${DUR[@]}"; }

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

# --- the wire stays up: follow the app's capture substream ------------------
# Why this exists. GrainBrick does NOT hold an input open. It spawns a fresh
# `arecord` for every take (AudioRecorder.start; stop sends SIGINT so the WAV
# header gets written), and it re-resolves its USB device by name immediately
# before each capture ("USB device is resolved immediately before capture, so
# device numbers can change across KNULLI devices" — read out of the binary). It
# also flips freely between BUILT-IN MIC and USB AUDIO in the same session, and
# aplay/arecord on a loopback card get whatever substream is free at that
# moment. So a feed that picks a substream once, at startup, is wrong by
# construction: the second take lands on another sub, the feed keeps writing
# the first one, and the app records exact zeros while `feed status` says
# running. That is the whole class of "mic works, USB doesn't" reports.
#
# So the feed is a supervisor, not a one-shot:
#   * nothing recording          -> drain the bytes into /dev/null. The Mac's
#                                   capture must never block on us; a blocked
#                                   ssh channel is input-side delay that is
#                                   never given back.
#   * the app holds a capture sub -> write THIS card's paired playback sub.
#   * the sub changed, or aplay died -> respawn against the new sub, re-reading
#                                   hw_params (the app sets rate/channels per
#                                   source: mic is mono, USB is stereo).
# `--sub N` still means "pin it there" — that is how you feed a stream that is
# open but not yet started, and it disables the follow.
sync_params() {
    local s=$1 r c f
    r=$(hp rate "$s"); c=$(hp channels "$s"); f=$(hp format "$s")
    [ -n "$r" ] && RATE=$r
    [ -n "$c" ] && CH=$c
    [ -n "$f" ] && FMT=$f
}

supervise() {
    local prev="" pid="" want dies=0
    FEED_FAST=1
    while :; do
        want=$(pick_sub)
        [ -n "$WANT_SUB" ] && want="$WANT_SUB"
        if [ "$want" = "$prev" ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            sleep 0.2; continue
        fi
        [ -n "$pid" ] && { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; pid=""; }
        # A writer that dies on the sub we just chose (the paired playback sub
        # held by a stale feed, say) must not turn this into a 5 Hz respawn loop
        # of the same error — back off, but keep trying, because the stale
        # holder may be on its way out.
        if [ "$want" = "$prev" ]; then dies=$((dies+1)); else dies=0; fi
        [ "$dies" -ge 3 ] && sleep 0.5
        # `<&0` IS THE WHOLE FEED. An asynchronous command in a non-interactive
        # shell gets /dev/null for stdin before any explicit redirection — POSIX,
        # and bash obeys it — so `play 0 &` started aplay with an instant EOF: it
        # opened the cable, wrote nothing, exited 0, and the supervisor respawned
        # it twice a second, printing "recording on capture sub 0" every time while
        # the app recorded exact zeros. That is this script's own version of the
        # bug it exists to fix, and `feed status` could not see it: the supervisor
        # WAS alive, its child simply never had any bytes. `cat > /dev/null &` was
        # wrong the same way — it drained nothing and exited at once, so the drain
        # branch spun too and the Mac's capture blocked on a pipe nobody read.
        if [ -n "$want" ]; then
            sync_params "$want"
            echo "audio_feed: $TARGET recording on capture sub $want -> writing playback sub $want (${RATE}Hz/$CH/$FMT)" >&2
            play "$want" <&0 &
        else
            [ -n "$prev" ] && echo "audio_feed: $TARGET stopped recording; draining (bytes discarded, wire kept live)" >&2
            cat > /dev/null <&0 &
            pid=$!; prev="$want"
            # If the drain child dies at once, stdin is at EOF — the host stopped
            # feeding us. Its capturer does die: ScreenCaptureKit exits with -3805
            # "application connection being interrupted" when the display it taps
            # goes away. Spinning on a closed pipe would keep `feed status`
            # reporting a live feed that can only ever write silence, which is the
            # lie this script exists to prevent. Say so and let the host wrapper
            # restart the pair.
            sleep 0.3
            kill -0 "$pid" 2>/dev/null && continue
            echo "audio_feed: $TARGET: the host feed ended (stdin closed) — exiting" >&2
            exit 1
        fi
        pid=$!; prev="$want"
        # An explicit --sub is a pin: nothing to follow, just keep it alive.
        [ -n "$WANT_SUB" ] && { wait "$pid" 2>/dev/null; pid=""; prev=""; }
    done
}

case "$MODE" in
    tone) tone | play "$SUB";;
    # aplay understands WAV itself, but only if the file already matches the
    # capture's channels — so convert first and keep one raw path.
    wav)  wav_to_raw | play "$SUB";;
    stdin) supervise;;
esac
