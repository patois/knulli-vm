#!/bin/bash
# In-guest: read the app's output cables and put them on stdout for the Mac.
#
#   usage: audio_capture.sh                    # holds every substream on the card
#          GB_OUT_SUBS="0 1" audio_capture.sh  # ... or only these
#
# WHY THERE IS MORE THAN ONE CABLE NOW. This script used to read exactly one
# substream, hw:Loopback,1,0, because the chroot's `default` mixed every client
# onto one through dmix. That mixer turned out to be the "enormous delay that will
# not clear": dmix will not mix past the slowest client's position, and GrainBrick
# holds one ALSA stream (pygame/SDL2, opened at startup) that it never writes a
# frame to, so the shared mix position was pinned at 0 for 35 hours and a click
# written through `default` reached the cable as nine seconds of exact zeros. The
# routing is now a direct stream per client (see setup_audio.sh), which has no
# shared position anyone can pin — and snd-aloop therefore hands each client its
# own substream again.
#
# The answer is not to guess which sub matters. It is to hold them all wired all
# the time: one reader per substream, permanently, summed. Nothing is discovered
# or re-selected while music is playing, which was the failure the old single
# cable was chosen to avoid.
#
# EVERY sub, not the first two. Holding a cable costs nothing: aloop's playback
# and capture are different streams, so a reader never locks the app out of the
# matching playback sub, and a loopback playback stream can only advance while
# something reads its far end, so a cable already held is the one that never makes
# the app wait. Subs this card does not have are not opened — they are enumerated
# from /proc rather than assumed, because a reader failing on a missing sub would
# respawn forever against a number that never existed.
#
# The card is named, never numbered (setup_audio.sh pins it to index 2 today,
# and the day it isn't is exactly the day a number in two scripts disagrees with
# a number in one), and the /proc/asound/cards lookup is not decoration: the name
# goes straight to arecord, so without the check a missing card fails as an
# arecord error instead of a sentence saying which card to go make.
# tools/audio_static_mix_test.sh covers the cables themselves, on this card,
# with the app running.
#
# Runs as root (the guest user is not in the audio group). -B/-F below are
# microseconds, and here they are latency rather than slack: this buffer sits in
# front of a stream that is already being clocked at 48 kHz, so every microsecond
# of it is delivered to the Mac late. 10 ms/2.5 ms, alongside a writer capped
# at 21 ms (brick_aplay.sh's KMAXBUFFER) and a player holding 30 ms.
set -u
CARD_NAME=Loopback
CARD=$(awk -v n="$CARD_NAME" '/\][[:space:]]*:/ && (index($0,"[" n "]") || index($0,"[" n " ")) {print $1; exit}' /proc/asound/cards)
[ -n "$CARD" ] || { echo "audio_capture: no '$CARD_NAME' sound card (run setup_audio.sh)" >&2; exit 1; }
if [ -z "${GB_OUT_SUBS:-}" ]; then
    # Every capture substream this card actually has (device 1 is the far end of
    # the device 0 the app writes), in order.
    # `echo`, not bare `tr -dc 0-9`: without a newline between names the digits
    # ran together ("01234567") and python opened one bogus sub 1234567 — the
    # whole output path died at startup while `audio status` still said streaming.
    GB_OUT_SUBS=$(for d in /proc/asound/card"$CARD"/pcm1c/sub*; do
                      [ -e "$d/status" ] || continue
                      echo "${d##*sub}"; done | tr '\n' ' ')
fi
[ -n "${GB_OUT_SUBS// /}" ] || { echo "audio_capture: no capture substreams on card $CARD" >&2; exit 1; }
exec python3 -u - "$CARD" "$GB_OUT_SUBS" <<'PY'
"""Sum every live output cable of one loopback card onto stdout as S16 stereo.

One arecord per substream, each on its own thread, into a per-cable buffer; the
main loop waits for a 10 ms block to exist, mixes every cable (saturating add)
and writes it, paced to the wall clock. A cable that falls more than ~60 ms
behind has its stale backlog
dropped rather than replayed — the same policy the Mac side applies (audioplay
drops instead of falling further behind), for the same reason: an instrument that
arrives late is worse than one that skips a frame, and this is the only place in
the chain positioned to see a stall coming from the guest side.
"""
import array, signal, subprocess, sys, threading, time

CARD, HOLD = sys.argv[1], [int(s) for s in sys.argv[2].split()]
RATE, CH = 48000, 2
BLOCK = RATE // 100                      # 10 ms; matches audioplay's chunk
CAP = 6 * BLOCK * CH                     # samples one cable may queue (~60 ms):
                                         # enough slack to ride out an ssh burst,
                                         # short enough that stale audio is
                                         # dropped rather than replayed late
ARECORD = ["arecord", "-f", "S16_LE", "-r", str(RATE), "-c", str(CH), "-t", "raw",
           "-q", "-B", "10000", "-F", "2500"]

class Source:
    """One cable: an arecord on capture device 1 sub `sub`, drained by a thread."""
    def __init__(self, sub):
        self.sub, self.buf, self.err, self.dead = sub, array.array("h"), "", False
        self.born = time.time()
        self.lock = threading.Lock()
        self.p = subprocess.Popen(ARECORD + ["-D", f"hw:{CARD},1,{sub}"],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        threading.Thread(target=self._pump, daemon=True).start()
        threading.Thread(target=self._drain_err, daemon=True).start()

    def _pump(self):
        while True:
            data = self.p.stdout.read(BLOCK * CH * 2)      # exactly one block
            if not data:
                break
            a = array.array("h"); a.frombytes(data)
            with self.lock:
                if not self.buf:
                    self.first_byte = time.time()   # when THIS cable went live
                self.buf.extend(a)
                if len(self.buf) > CAP:
                    del self.buf[:len(self.buf) - CAP]
        self.dead = True

    def _drain_err(self):
        self.err = self.p.stderr.read().decode(errors="replace").strip()

    def buf_ready(self, frames):
        with self.lock:
            return len(self.buf) >= frames * CH

    def take(self, frames):
        """Up to `frames` interleaved frames, zero-padded if the cable is short."""
        with self.lock:
            have = self.buf[:frames * CH]
            del self.buf[:frames * CH]
        if len(have) < frames * CH:
            have.extend([0] * (frames * CH - len(have)))
        return have

    def stop(self):
        try:
            self.p.kill()
        except OSError:
            pass

def main():
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)   # the Mac went away: just die
    srcs = {s: Source(s) for s in HOLD}
    out = sys.stdout.buffer
    t_next = None
    while True:
        for s in [s for s, x in srcs.items() if x.dead]:
            x = srcs.pop(s); x.stop()
            why = x.err.splitlines()[0] if x.err else "no data"
            print(f"audio_capture: sub {s} reader exited after "
                  f"{time.time() - x.born:.1f}s ({why})", file=sys.stderr, flush=True)
            # Every cable is held, so every cable comes back — but not one that
            # died within its first two seconds: the reason it failed (something
            # else holds the sub) will still be there, and the message above is
            # the diagnosis either way.
            if time.time() - x.born > 2:
                srcs[s] = Source(s)
        if not srcs:
            time.sleep(0.05); continue
        # Wait for data before writing a block — but then pace the WRITE to the
        # wall clock. "Bytes are the clock" was true when exactly one cable was
        # held: with eight, the gate fires whenever any one of them has a block
        # ready, and take() zero-pads the cables that do not — so the loop can
        # run faster than 40 Hz (measured 1.65x with every cable verified to
        # deliver realtime at /proc level), inventing output the inputs never
        # produced, which pushes real audio past the CAP trim (dropped) and
        # fills audioplay's queue past its ceiling (choppy, and everything
        # hears it late). A mixer's output clock is the wall clock; data
        # presence only says whether THIS block may go out yet.
        while not any(x.buf_ready(BLOCK) for x in srcs.values()):
            time.sleep(0.002)
        now = time.time()
        if t_next is None or now - t_next > BLOCK / RATE:
            t_next = now          # starting, or fell behind: restart the clock.
                                  # Catching up would replay the backlog late,
                                  # which is exactly the thing this loop must
                                  # never do (audioplay drops for the same why).
        else:
            time.sleep(max(0.0, t_next - now))   # max(): up to one block behind
                                                 # yet (the branch above restarts
                                                 # only past that), and sleep()
                                                 # rejects negatives.
        t_next += BLOCK / RATE
        mix = [0] * BLOCK * CH
        for x in srcs.values():
            for i, v in enumerate(x.take(BLOCK)):
                n = mix[i] + v
                mix[i] = -32768 if n < -32768 else (32767 if n > 32767 else n)
        try:
            out.write(array.array("h", mix).tobytes()); out.flush()
        except BrokenPipeError:
            break
    for x in srcs.values():
        x.stop()

main()
PY
