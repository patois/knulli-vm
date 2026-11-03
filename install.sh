#!/bin/bash
# knulli-vm installer: creates a Lima VM (Ubuntu arm64), extracts the KNULLI
# OS userspace from a device image, makes it runnable in the VM (SDL x11
# compat build), and optionally installs apps (GrainBrick etc.) into it.
#
#   ./install.sh                                   # download latest knulli for
#                                                  #   TrimUI Brick, VM "knulli-vm"
#   ./install.sh --image ./knulli-....img          # use a downloaded image
#   ./install.sh --image-url https://.../x.img.gz  # fetch a specific build
#   ./install.sh --image-device knulli-h700-rg-cubexx
#   ./install.sh --app ~/Downloads/GrainBrick_beta_1.0_TrimUI_Brick_KNULLI.zip
#   ./install.sh --vm-name other --vnc-port 5902 --vnc-pass secret --app <url>
#                                                  # (two installs on one Mac
#                                                  #   cannot both own 5901)
#
# Nothing downloaded lands in git (see .gitignore). The KNULLI image itself
# cannot boot under Virtualization.framework (device SoC firmware); we boot
# Ubuntu and chroot the image's squashfs userspace instead — see README.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
STATE="$HERE/state"; DL="$HERE/downloads"

VM="knulli-vm"; IMAGE=""; IMAGE_URL=""; DEVICE="knulli-a133-trimui-brick"
VNC_PASS="knulli"; VNC_PORT=5901; APPS=()

die() { echo "install: $*" >&2; exit 1; }
say() { echo ">>> $*"; }

# heartbeat LABEL PID — prints an elapsed-time line every 15 s while PID
# lives, then stops. The slow steps (unsquashfs, cmake, limactl boot) have
# their verbose output silenced on purpose, which otherwise reads as a
# hang on a first install; a ticking clock is the difference between
# "working" and "frozen". Caller still collects the exit code with wait.
heartbeat() {
    local label="$1" pid="$2" t=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 15; t=$((t + 15))
        kill -0 "$pid" 2>/dev/null || break
        say "$label ... ${t}s"
    done
}

while [ $# -gt 0 ]; do
    case "$1" in
        --image) IMAGE="$2"; shift 2;;
        --image-url) IMAGE_URL="$2"; shift 2;;
        --image-device) DEVICE="$2"; shift 2;;
        --vm-name) VM="$2"; shift 2;;
        --vnc-pass) VNC_PASS="$2"; shift 2;;
        --vnc-port) VNC_PORT="$2"; case "$VNC_PORT" in (*[!0-9]*|'') die "--vnc-port needs a number, got '$2'";; esac; shift 2;;
        --app) APPS+=("$2"); shift 2;;
        -h|--help) sed -n '2,22p' "$0"; exit 0;;
        *) die "unknown flag $1";;
    esac
done

# ---- 0. prerequisites ---------------------------------------------------------
[ "$(uname -s)" = Darwin ] || die "this installer targets the macOS host (Lima/vz)"
[ "$(uname -m)" = arm64 ] || die "aarch64 guest == host arch is required (Apple Silicon)"
command -v limactl >/dev/null || die "limactl not found — install lima:  brew install lima"
command -v python3 >/dev/null || die "python3 not found (xcode-select --install)"

gexec() { limactl shell "$VM" -- bash -lc "$1"; }

# ---- 1. create/start the VM ----------------------------------------------------
# limactl's output goes to a BOOTLOG, never /dev/null: a first run spends
# minutes downloading the Ubuntu image, and when it FAILED the old version
# hid why and just polled to its 450 s deadline, killing its own still-
# progressing limactl at the buzzer — which read as "stuck in a loop
# failing to boot". Now: fail the moment limactl dies (with its tail),
# poll patiently while it lives, and never kill a healthy start.
mkdir -p "$STATE"
BOOTLOG="$STATE/$VM.boot.log"
if ! limactl list --json 2>/dev/null | grep -q "\"name\":\"$VM\".*\"status\":\"Running\""; then
    if ! limactl list 2>/dev/null | grep -q "^$VM[[:space:]]"; then
        say "creating VM '$VM' (Ubuntu 24.04 arm64, vz; first run downloads the OS image)"
        # template form only for NEW instances — limactl rejects a template
        # for an instance that already exists (it errored out instantly on a
        # stopped VM while the poll loop waited for a boot that never came)
        limactl start "$HERE/vm/knulli.yaml" --name "$VM" >"$BOOTLOG" 2>&1 &
    else
        say "starting VM '$VM'"
        limactl start "$VM" >"$BOOTLOG" 2>&1 &
    fi
    SP=$!
    tv=0
    while :; do
        limactl list --json 2>/dev/null | grep -q "\"name\":\"$VM\".*\"status\":\"Running\"" && break
        if ! kill -0 "$SP" 2>/dev/null; then
            tail -5 "$BOOTLOG" >&2
            die "VM '$VM' failed to start (full limactl output: $BOOTLOG)"
        fi
        sleep 5; tv=$((tv + 5))
        [ $((tv % 30)) -eq 0 ] && say "waiting for VM to boot ... ${tv}s (limactl: tail -f $BOOTLOG)"
        [ "$tv" -ge 1800 ] && { tail -5 "$BOOTLOG" >&2; die "VM '$VM' not Running after 30 min — check $BOOTLOG"; }
    done
    wait "$SP" 2>/dev/null || true
fi
# "Running" only means the hypervisor process is alive — cloud-init can
# still be holding ssh at "Connection refused" for tens of seconds after,
# and every deploy call then fails confusingly (observed: fresh VM,
# "failed to deploy ... Connection refused"). Wait for ssh to answer.
sv=0
until limactl shell "$VM" -- true 2>/dev/null; do
    sleep 5; sv=$((sv + 5))
    [ $((sv % 30)) -eq 0 ] && say "waiting for guest ssh ... ${sv}s"
    [ "$sv" -ge 180 ] && die "guest ssh never answered on '$VM' (inspect: limactl shell $VM)"
done
say "VM '$VM' is up"

# ---- 2. deploy guest scripts ---------------------------------------------------
# Directory-driven on purpose: hand-maintained lists drifted before
# (audio_capture.sh went undeployed — fresh installs silently mute with
# every step green), so EVERY file in lib/guest/ ships, no list to forget.
# A failed copy aborts: printing "deployed" after failures sends you off to
# debug the wrong machine.
mkdir -p "$STATE"
gexec "mkdir -p ~/knulli-vm"
for f in "$HERE"/lib/guest/*; do
    [ -f "$f" ] || die "no guest scripts in lib/guest/ (corrupted checkout?)"
    limactl shell "$VM" -- bash -lc "install -m 755 /dev/stdin ~/knulli-vm/$(basename "$f")" < "$f" \
        || die "failed to deploy lib/guest/$(basename "$f") to the guest"
done
say "guest scripts deployed to ~/knulli-vm"

# ---- 2b. guest packages --------------------------------------------------------
# The lima template provisions these, but templates only apply at VM CREATION
# — VMs built from an older template (and thus every install made before
# tigervnc was added to it) must be able to heal by re-running this script.
# run_app.sh deliberately never runs apt itself, so this is the one place
# display/input deps get ensured. Only touches what's actually missing.
say "ensuring guest display/input packages"
limactl shell "$VM" -- bash -lc '
    need=()
    command -v Xvnc       >/dev/null 2>&1 || need+=(tigervnc-standalone-server tigervnc-common tigervnc-tools)
    command -v xdotool    >/dev/null 2>&1 || need+=(xdotool)
    command -v Xvfb       >/dev/null 2>&1 || need+=(xvfb x11vnc)
    command -v import     >/dev/null 2>&1 || need+=(imagemagick)
    python3 -c "import Xlib" >/dev/null 2>&1 || need+=(python3-xlib)
    if [ ${#need[@]} -eq 0 ]; then echo "all present"; exit 0; fi
    echo "installing: ${need[*]}"
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        -o DPkg::Lock::Timeout=120 "${need[@]}"
' </dev/null & hp=$!
heartbeat "apt in guest" $hp
wait $hp || say "WARNING: guest package install failed — VNC may fall back or keyboard mapping be off"

# ---- 3. obtain the knulli image ------------------------------------------------
ROOTFS=$(gexec 'echo $HOME/knulli-root')
mkdir -p "$DL"
if gexec "test -d '$ROOTFS/usr/lib/python3.12/site-packages/pygame'" 2>/dev/null; then
    # The image is only a carrier for the squashfs; once the rootfs exists
    # it is no longer needed — a re-run must not re-download 2 GB.
    say "rootfs already extracted — skipping image fetch (pass --image to re-extract)"
    IMAGE=$(grep '^IMAGE=' "$STATE/$VM.conf" 2>/dev/null | cut -d= -f2- || true)
    IMAGE="${IMAGE:-already-extracted}"
elif [ -n "$IMAGE" ]; then
    [ -f "$IMAGE" ] || die "image not found: $IMAGE"
    IMAGE=$(cd "$(dirname "$IMAGE")" && pwd)/$(basename "$IMAGE")
else
    if [ -z "$IMAGE_URL" ]; then
        say "resolving latest knulli release for '$DEVICE' (knulli-cfw/distribution)"
        IMAGE_URL=$(python3 - "$DEVICE" <<'PY'
import json, sys, urllib.request
dev = sys.argv[1]
r = json.load(urllib.request.urlopen(
    "https://api.github.com/repos/knulli-cfw/distribution/releases/latest"))
for a in r["assets"]:
    if a["name"].startswith(dev + "-") and a["name"].endswith(".img.gz"):
        print(a["browser_download_url"]); break
else:
    sys.exit(f"no .img.gz asset for device prefix '{dev}' in latest release")
PY
) || die "could not resolve a knulli image (use --image-url or --image)"
    fi
    gz="$DL/$(basename "$IMAGE_URL")"
    IMAGE="${gz%.gz}"
    # knulli's .sha256 release asset is a BARE hash (64 hex chars, no
    # filename field) — `shasum -c` rejects that as "no properly formatted
    # SHA checksum lines", which reads like a corrupt download and blocks
    # every install. Compare the hash value itself; tolerate either format.
    verify_gz() {
        if ! curl -fsL -o "$gz.sha256" "${IMAGE_URL}.sha256" 2>/dev/null; then
            say "WARNING: no .sha256 asset for this release — verification skipped"
            return 0
        fi
        want=$(grep -oiE '[0-9a-f]{64}' "$gz.sha256" | head -1)
        [ -n "$want" ] || { say "WARNING: unparsable .sha256 asset — verification skipped"; return 0; }
        say "verifying sha256"
        ( shasum -a 256 "$gz" > "$gz.have" ) & hp=$!
        heartbeat "hashing 2 GB" $hp
        wait $hp || { rm -f "$gz.have"; die "shasum failed"; }
        have=$(awk '{print $1}' "$gz.have"); rm -f "$gz.have"
        if [ "$have" != "$want" ]; then
            say "sha256 MISMATCH: want $want"
            say "                 have  $have"
            return 1
        fi
        say "sha256 OK"
    }
    if [ ! -f "$IMAGE" ]; then
        if [ -f "$gz" ]; then
            # A completed .gz from a previous run must be verified and
            # REUSED, not re-fetched: curl -C - on a complete file gets
            # HTTP 416 and dies "download failed" — a dead end after any
            # earlier failure (like the sha-format bug).
            if verify_gz; then
                say "existing download verified — skipping re-download"
            else
                say "existing download failed verification — re-downloading"
                rm -f "$gz" "$gz.sha256"
                curl -fL -o "$gz" "$IMAGE_URL" || die "download failed"
                verify_gz || die "sha256 mismatch"
            fi
        else
            say "downloading $IMAGE_URL (~2 GB)"
            curl -fL -C - -o "$gz" "$IMAGE_URL" || die "download failed"
            verify_gz || die "sha256 mismatch"
        fi
        say "gunzip"
        gunzip -c "$gz" > "$IMAGE" & hp=$!
        heartbeat "gunzip" $hp
        wait $hp || die "gunzip failed"
        rm -f "$gz" "$gz.sha256"
    else
        say "image already present: $IMAGE"
    fi
fi
say "image: $IMAGE"

# ---- 4. extract the knulli rootfs ----------------------------------------------
if [ -f "$IMAGE" ]; then
    # </dev/null: a backgrounded ssh would SIGTTIN-stop on reading the tty
    limactl shell "$VM" -- bash -lc "~/knulli-vm/extract_knulli.sh '$IMAGE' '$ROOTFS'" </dev/null & hp=$!
    heartbeat "extracting rootfs (unsquashfs runs in the guest)" $hp
    wait $hp || die "rootfs extraction failed"
fi

# ---- 5. SDL2 x11 compat build ---------------------------------------------------
limactl shell "$VM" -- bash -lc "~/knulli-vm/build_sdl2_x11.sh '$ROOTFS'" </dev/null & hp=$!
heartbeat "SDL2 x11 build (apt+cmake in guest)" $hp
wait $hp || die "SDL2 x11-compat build failed"

# ---- 5b. audio routing (loopback card -> Mac) -----------------------------------
limactl shell "$VM" -- bash -lc "~/knulli-vm/setup_audio.sh '$ROOTFS'" \
    || say "WARNING: audio setup failed (the app will be silent)"

# ---- 5c. VNC port ---------------------------------------------------------------
# Lima forwards the guest's VNC port to the SAME port on the Mac, and only one
# install can own 5901: a second install's forward silently never binds, so
# `knulli-vm vnc` printed a URL whose liveness probe passed — and the window it
# opened was the FIRST VM's screen. (Same trap if Screen Sharing or anything
# else on the Mac already serves that port.) Claim a port that is free, or
# already ours, so a re-run of an existing install keeps the port it has.
port_usable_by_us() {
    local p="$1" pid
    for pid in $(lsof -nP -iTCP:"$p" -sTCP:LISTEN -t 2>/dev/null); do
        ps -p "$pid" -o command= 2>/dev/null | grep -q "/\.lima/$VM/" || return 1
    done
    return 0
}
if ! port_usable_by_us "$VNC_PORT"; then
    say "Mac port $VNC_PORT is already served by another VM or app"
    want=$VNC_PORT
    until port_usable_by_us "$VNC_PORT"; do
        VNC_PORT=$((VNC_PORT + 1))
        [ "$VNC_PORT" -gt $((want + 50)) ] && \
            die "no free VNC port in $want..$((want + 50)) — pick one with --vnc-port"
    done
    say "using VNC port $VNC_PORT for this install (vnc://localhost:$VNC_PORT)"
fi

# ---- 6. config ------------------------------------------------------------------
# Write via a temp only if the whole block SUCCEEDS. The old trailing
# `[ -f "$CONF" ] && grep ...` made the block exit 1 on every FRESH install
# (no conf to preserve yet), so `&& mv` was skipped: conf.tmp left behind,
# no conf, yet state/default was written on the next line and the installer
# still said "ready" — every knulli-vm command then died "no config".
# grep-no-match-or-absent must be `|| true`, never a tested `[ -f ]`.
CONF="$STATE/$VM.conf"
{
    echo "VM_NAME=$VM"
    echo "ROOTFS=$ROOTFS"
    echo "VNC_PASS=$VNC_PASS"
    echo "VNC_PORT=$VNC_PORT"
    echo "IMAGE=$IMAGE"
    grep '^DEFAULT_APP=' "$CONF" 2>/dev/null || true
} > "$CONF.tmp" && mv "$CONF.tmp" "$CONF" || die "could not write $CONF"
echo "$VM" > "$STATE/default"
say "config: $CONF"

# ---- 7. host audio player ---------------------------------------------------
# Guest has no sound hardware; `knulli-vm audio` streams the loopback card
# over ssh into this CoreAudio sink (built with the Xcode CLT compiler).
# rebuild when stale too, not just when absent: an install from before the
# AVAudioEngine rewrite would otherwise keep running the old AudioQueue
# binary — which rendered nothing — through every later re-run.
if [ ! -x "$HERE/bin/audioplay" ] || \
   [ "$HERE/lib/host/audioplay.swift" -nt "$HERE/bin/audioplay" ]; then
    if command -v xcrun >/dev/null && xcrun --find swiftc >/dev/null 2>&1; then
        say "building host audio player (bin/audioplay)"
        mkdir -p "$HERE/bin"
        xcrun swiftc -O -o "$HERE/bin/audioplay" "$HERE/lib/host/audioplay.swift" & hp=$!
        heartbeat "swiftc" $hp
        wait $hp || say "WARNING: audioplay build failed — guest audio will be silent"
    else
        say "WARNING: no swiftc (xcode-select --install) — guest audio will be silent"
    fi
fi

# ---- 8. apps --------------------------------------------------------------------
for a in ${APPS[@]+"${APPS[@]}"}; do
    "$HERE/knulli-vm" --vm "$VM" app add "$a" --default || die "app add failed: $a"
done

# ---- 9. done ---------------------------------------------------------------------
echo
echo "knulli-vm ready."
if [ -d "$STATE/$VM.apps" ] && [ -n "$(ls -A "$STATE/$VM.apps" 2>/dev/null)" ]; then
    echo "  ./knulli-vm start          # launch the default app (+ audio to Mac)"
    echo "  open \$(./knulli-vm vnc)   # VNC in (password: $VNC_PASS)"
    echo "  keyboard on the VNC screen maps to the Brick's buttons:"
    echo "  WASD/arrows=dpad  j=A k=B u/x=X i=Y  q/e=L1/R1  z/c=L2/R2"
    echo "  Enter=Start  BackSpace=Select  m=Menu  F1/F2=tabs"
else
    echo "  no apps yet — e.g.:"
    echo "  ./knulli-vm app add /path/to/GrainBrick_beta_1.0_TrimUI_Brick_KNULLI.zip"
    echo "  ./knulli-vm start"
fi
