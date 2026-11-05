#!/bin/bash
# Static-cable test: prove every playback client reaches the ONE Mac cable.
#
#   ./tools/audio_static_mix_test.sh
#
# What it asserts, and why it exists. The output path is static wiring: the
# chroot's ALSA `default` mixes all playback clients through dmix onto a single
# aloop substream (lib/guest/setup_audio.sh), and the Mac reads the far end at
# hw:<card>,1,0 forever. "Static" is the whole claim, so the test is: play TWO
# clients at once through `default` and catch BOTH on that one cable, mixed,
# while GrainBrick sits there holding its always-on monitor stream. A design
# where the cable exists but carries only one client's audio is the bug this
# replaces — snd-aloop gives every opened stream its own substream, so without
# the mixer the second client is inaudible on the cable no matter how long you
# listen.
#
# Requirements: the audio PIPE must be down (`./knulli-vm audio stop`) — an
# aloop capture substream is exclusive, so a second capturer gets "Device or
# resource busy" rather than a share; this script turns that into a clear error
# instead of a silent zero. The APP may stay up (it should — its monitor stream
# being the mixer's master while other clients mix in is the real condition).
# Feed scripts can stay up; they write the other card.
#
# TWO MEASUREMENT TRAPS THAT LIVE IN THE ANALYZER — do not "simplify" them:
#   1. Stereo int16 = 4 bytes per FRAME. Unpacking a frame as one int32 yields
#      peaks like 589833000 (impossible) and, if you then stride by 2, decimates
#      the 48 kHz signal and every tone reads as silence. Unpack '<%dh' over
#      len/2 samples and take every other SAMPLE. This exact bug reported a
#      working mixer as "pure zeros" and cost a debugging cycle.
#   2. Zeros must be distinguishable from "no bytes". Report the byte count
#      next to the levels; a dead cable returns full-length buffers of zeros.
# A 1000 Hz control tone is measured too: real leakage there means the mix is
# distorted, not mixed.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
KV="$HERE/knulli-vm"
VM="${KNV_VM:-$(cat "$HERE/state/default" 2>/dev/null || echo knulli-vm)}"
gexec() { limactl shell "$VM" -- bash -lc "$1"; }

# The pipe holds the capture sub this test needs.
if gexec 'pgrep -f "arecord -D hw:Loopback[,]" >/dev/null 2>&1'; then
    echo "audio_static_mix_test: the Mac audio pipe is capturing hw:Loopback right now." >&2
    echo "  Run '$KV audio stop' first (it owns the capture substream this test reads)." >&2
    exit 1
fi

GUEST=$(mktemp -t knv-mixtest.XXXXXX)
trap 'rm -f "$GUEST"' EXIT
cat >"$GUEST" <<'EOS'
#!/bin/bash
# Runs as the GUEST user. Guest $HOME is /home/user.guest and `sudo bash x.sh`
# makes ~ = /root, so every guest path here is absolute — never built from ~.
set -u
R=/home/user.guest/knulli-root
CH=/home/user.guest/knulli-vm/knulli-chroot.sh
python3 -I - <<'PY'
import math, struct
sr = 48000
for path, freq in (('/tmp/knv-mix440.raw', 440.0), ('/tmp/knv-mix660.raw', 660.0)):
    out = bytearray()
    for i in range(sr * 6):
        v = int(9000 * math.sin(2 * math.pi * freq * i / sr))
        out += struct.pack('<hh', v, v)
    open(path, 'wb').write(bytes(out))
PY
sudo cp -f /tmp/knv-mix440.raw /tmp/knv-mix660.raw "$R/tmp/" || exit 1
# -q off: an XRUN in a client is the failure we are looking for, so keep stderr.
sudo "$CH" "aplay -D default -t raw -f S16_LE -r 48000 -c 2 /tmp/knv-mix440.raw" >/tmp/knv-mix-a.log 2>&1 &
A=$!
sleep 0.5
sudo "$CH" "aplay -D default -t raw -f S16_LE -r 48000 -c 2 /tmp/knv-mix660.raw" >/tmp/knv-mix-b.log 2>&1 &
B=$!
sleep 1.2
# comm must be aplay itself: -f matching alone also counts the `sudo chroot`
# wrappers, whose command line contains the same text.
echo "  clients playing : $(ps -eo comm=,args= | awk '/\/tmp\/knv-mix/ && $1 == "aplay"' | wc -l | tr -d ' ') (want 2)"
echo "  running playback subs: $(for s in /proc/asound/card2/pcm0p/sub*/status; do grep -qm1 'state: RUNNING' "$s" 2>/dev/null && printf 'x'; done | wc -c | tr -d ' ') (dmix means exactly 1)"
sudo arecord -D hw:Loopback,1,0 -f S16_LE -r 48000 -c 2 -t raw -q -d 2 >/tmp/knv-mix.raw 2>/tmp/knv-mix-err.txt
RC=$?
sudo kill $A $B 2>/dev/null; sudo rm -f "$R/tmp/knv-mix440.raw" "$R/tmp/knv-mix660.raw"
[ "$RC" = 0 ] || { echo "  arecord on hw:Loopback,1,0 FAILED (busy? pipe still up?):" >&2
                   sed 's/^/    /' /tmp/knv-mix-err.txt >&2; exit 1; }
for f in /tmp/knv-mix-a.log /tmp/knv-mix-b.log; do
    grep -i 'xrun\|broken\|unable\|busy' "$f" | head -2 | sed 's/^/  client: /'
done
python3 -I - <<'PY'
import struct, math
d = open('/tmp/knv-mix.raw', 'rb').read()
n = len(d) // 2                                   # int16 SAMPLES, not frames
s = struct.unpack('<%dh' % n, d[:n * 2]) if n else ()
L = s[0::2]                                       # left of each stereo pair (48 kHz)
if not L:
    print("  FAIL: captured 0 bytes on hw cable"); raise SystemExit(1)
def amp(f, count=24000):                          # full-rate Goertzel, no striding
    m = min(count, len(L))
    re = im = 0.0
    for k in range(m):
        a = 2.0 * math.pi * f * k / 48000.0
        re += L[k] * math.cos(a); im -= L[k] * math.sin(a)
    return 2.0 * math.hypot(re, im) / m
a440, a660, ctl = amp(440), amp(660), amp(1000)
peak = max(abs(x) for x in L)
nz = sum(1 for x in L if x) * 100.0 / len(L)
print("  captured %d bytes  peak=%d  nonzero=%.1f%%" % (len(d), peak, nz))
for f, v in ((440, a440), (660, a660), (1000, ctl)):
    print("  %4d Hz -> %7.0f%s" % (f, v, "   (control: must be ~0)" if f == 1000 else ""))
ok = a440 > 5000 and a660 > 5000 and ctl < 500 and peak > 8000 and peak < 32000
print("  %s" % ("PASS: both clients mixed onto the one static cable" if ok else
                "FAIL: expected BOTH tones > 5000, control < 500, no clipping"))
raise SystemExit(0 if ok else 1)
PY
RC=$?
sudo rm -f /tmp/knv-mix440.raw /tmp/knv-mix660.raw /tmp/knv-mix-a.log /tmp/knv-mix-b.log \
       /tmp/knv-mix-err.txt
exit $RC
EOS

echo "audio_static_mix_test: two clients -> chroot 'default' (dmix) -> hw:Loopback,1,0"
limactl copy "$GUEST" "$VM":/tmp/knv-mixtest.sh >/dev/null 2>&1 || { echo "copy into VM failed" >&2; exit 1; }
gexec 'bash /tmp/knv-mixtest.sh'
RC=$?
gexec 'rm -f /tmp/knv-mixtest.sh' >/dev/null 2>&1
[ "$RC" = 0 ] && echo "note: run '$KV audio start' to bring the Mac pipe back up"
exit $RC
