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
#   ./install.sh --vm-name other --vnc-pass secret --app <dir-or-url> ...
#
# Nothing downloaded lands in git (see .gitignore). The KNULLI image itself
# cannot boot under Virtualization.framework (device SoC firmware); we boot
# Ubuntu and chroot the image's squashfs userspace instead — see README.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
STATE="$HERE/state"; DL="$HERE/downloads"

VM="knulli-vm"; IMAGE=""; IMAGE_URL=""; DEVICE="knulli-a133-trimui-brick"
VNC_PASS="knulli"; APPS=()

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
        --app) APPS+=("$2"); shift 2;;
        -h|--help) sed -n '2,20p' "$0"; exit 0;;
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
if ! limactl list --json 2>/dev/null | grep -q "\"name\":\"$VM\".*\"status\":\"Running\""; then
    if ! limactl list 2>/dev/null | grep -q "^$VM[[:space:]]"; then
        say "creating VM '$VM' (Ubuntu 24.04 arm64, vz; first run downloads the OS image)"
    else
        say "starting VM '$VM'"
    fi
    limactl start "$HERE/vm/knulli.yaml" --name "$VM" >/dev/null 2>&1 &
    SP=$!
    tv=0
    for _ in $(seq 1 90); do
        limactl list --json 2>/dev/null | grep -q "\"name\":\"$VM\".*\"status\":\"Running\"" && break
        sleep 5; tv=$((tv + 5))
        [ $((tv % 30)) -eq 0 ] && say "waiting for VM to boot ... ${tv}s"
    done
    kill "$SP" 2>/dev/null
    limactl list | grep -q "^$VM[[:space:]].*Running" || \
        die "VM failed to start (note: lima can stall on its optional containerd step; try 'limactl shell $VM' manually)"
fi
say "VM '$VM' is up"

# ---- 2. deploy guest scripts ---------------------------------------------------
# Keep this list in sync with lib/guest/ (knulli-vm sync has its own copy of
# the list): a missing entry silently breaks its feature on fresh installs —
# audio_capture.sh absent meant "the app is silent" with every step green.
# A failed copy must abort: printing "deployed" after failures sends you off
# to debug the wrong machine.
mkdir -p "$STATE"
gexec "mkdir -p ~/knulli-vm"
for f in knulli-chroot.sh virtual_joypad.py run_app.sh setup_audio.sh keymapd.py \
         focusd.sh extract_knulli.sh build_sdl2_x11.sh sdl_pad_probe.py audio_capture.sh; do
    [ -f "$HERE/lib/guest/$f" ] || die "missing lib/guest/$f (corrupted checkout?)"
    limactl shell "$VM" -- bash -lc "install -m 755 /dev/stdin ~/knulli-vm/$f" < "$HERE/lib/guest/$f" \
        || die "failed to deploy lib/guest/$f to the guest"
done
say "guest scripts deployed to ~/knulli-vm"

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
    if [ ! -f "$IMAGE" ]; then
        say "downloading $IMAGE_URL (~2 GB)"
        curl -fL -C - -o "$gz" "$IMAGE_URL" || die "download failed"
        sha_url="$IMAGE_URL.sha256"
        if curl -fsL -o "$gz.sha256" "$sha_url" 2>/dev/null; then
            say "verifying sha256"
            (cd "$DL" && shasum -a 256 -c "$(basename "$gz").sha256") & hp=$!
            heartbeat "hashing 2 GB" $hp
            wait $hp || die "sha256 mismatch"
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

# ---- 6. config ------------------------------------------------------------------
CONF="$STATE/$VM.conf"
{
    echo "VM_NAME=$VM"
    echo "ROOTFS=$ROOTFS"
    echo "VNC_PASS=$VNC_PASS"
    echo "IMAGE=$IMAGE"
    [ -f "$CONF" ] && grep '^DEFAULT_APP=' "$CONF"
} > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
echo "$VM" > "$STATE/default"
say "config: $CONF"

# ---- 7. host audio player ---------------------------------------------------
# Guest has no sound hardware; `knulli-vm audio` streams the loopback card
# over ssh into this CoreAudio sink (built with the Xcode CLT compiler).
if [ ! -x "$HERE/bin/audioplay" ]; then
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
