#!/bin/bash
# In-guest: extract the KNULLI OS userspace from a device image into a
# chrootable rootfs. Image layout (GPT): protective MBR; partition table
# entries carry firstLBA at entry offset **32** (not 16 — common gotcha);
# a FAT32 "boot-resource" partition holds the OS squashfs (zstd) under
# boot/ — named boot/knulli on scarab-era images, boot/batocera on the
# older batocera-fork-era builds (gladiator-ii et al.), hence the
# candidate list + magic-scan fallback below.
#   usage: extract_knulli.sh <image-path> <dest-dir>
set -euo pipefail
IMG="$1"; DEST="$2"
SUDO=sudo

[ -r "$IMG" ] || { echo "cannot read image: $IMG" >&2; exit 1; }
command -v unsquashfs >/dev/null || { echo "squashfs-tools missing in guest" >&2; exit 1; }

# Check the destination BEFORE touching the image: a re-run against an
# already-extracted rootfs must return immediately, not re-parse/re-mount.
if [ -d "$DEST" ] && ! $SUDO find "$DEST" -maxdepth 0 -empty 2>/dev/null | grep -q .; then
    if $SUDO test -d "$DEST/usr/lib/python3.12/site-packages/pygame" 2>/dev/null; then
        echo "rootfs already extracted at $DEST — skipping"
        exit 0
    fi
    echo "ERROR: $DEST exists and is not an extracted knulli rootfs; refusing to touch it" >&2
    exit 1
fi

# --- locate the FAT32 boot-resource partition -------------------------------
read -r OFF SIZE <<<"$(python3 - "$IMG" <<'PY'
import struct, sys
# GPT header at LBA1; partition entries carry firstLBA/lastLBA at entry
# offsets 32/40 (offset 16 is the GUID — misreading it is a classic trap).
f = open(sys.argv[1], "rb")
f.seek(512)
hdr = f.read(92)
sig = hdr[:8]
assert sig == b"EFI PART", "no GPT header at LBA1"
pe_lba, num, esz = struct.unpack("<QII", hdr[72:88])
MS_BASIC_DATA = bytes.fromhex("a0a0d0eb e5b9 3344 87c0 68b6b72699c7".replace(" ", ""))
f.seek(pe_lba * 512)
cands = []
for i in range(num):
    e = f.read(esz)
    if e[:16] == bytes(16):
        continue
    first, last = struct.unpack("<QQ", e[32:48])
    name = e[56:128].decode("utf-16le", "ignore").split("\0")[0]
    cands.append((name, e[:16] == MS_BASIC_DATA, first * 512, (last - first + 1) * 512))
fat = next((c for c in cands if "resource" in c[0].lower()), None)
if fat is None:  # fallback: first basic-data partition that is really FAT
    for name, basic, off, size in cands:
        if not basic or size > 1 << 30:
            continue
        f.seek(off)
        if f.read(90)[82:85] == b"FAT":
            fat = (name, basic, off, size)
            break
if fat is None:
    sys.exit("no FAT boot-resource partition found; cands=%r" % (cands,))
print(fat[2], fat[3])
PY
)"
echo "boot-resource partition: offset=$OFF size=$SIZE"

# --- pull boot/knulli (the OS squashfs) out of the FAT32 partition ----------
MNT=$($SUDO mktemp -d /mnt/knulli-br.XXXXXX)   # /mnt is root-writable only
umount_br() { $SUDO umount "$MNT" 2>/dev/null || true; $SUDO rmdir "$MNT" 2>/dev/null || true; }
trap umount_br EXIT
$SUDO mount -o ro,loop,offset="$OFF" "$IMG" "$MNT"
# Try the known names across knulli eras first; then fall back to scanning
# every file for the squashfs magic (hsqs), largest match wins — so a future
# rename cannot strand the extractor.
SQ=""
for cand in knulli batocera knulli.update batocera.update; do
    [ -f "$MNT/boot/$cand" ] && { SQ="$MNT/boot/$cand"; break; }
done
if [ -z "$SQ" ]; then
    best=0
    while IFS= read -r f; do
        [ "$($SUDO head -c4 "$f" 2>/dev/null)" = hsqs ] || continue
        sz=$($SUDO stat -c%s "$f")
        [ "$sz" -gt "$best" ] && { SQ="$f"; best=$sz; }
    done < <($SUDO find "$MNT" -type f 2>/dev/null)
fi
[ -n "$SQ" ] || { echo "no OS squashfs in boot-resource (tried boot/knulli, boot/batocera, .update variants, magic scan)" >&2; exit 1; }
echo "OS squashfs: ${SQ#"$MNT"}"
TMP_SQ="$HOME/knulli.sqsh"
echo "copying squashfs ($(stat -c%s "$SQ") bytes) ..."
$SUDO install -m 644 -o "$(id -u)" -g "$(id -g)" "$SQ" "$TMP_SQ"
umount_br; trap - EXIT

# --- unsquashfs into the chroot dir -----------------------------------------
$SUDO mkdir -p "$DEST"
echo "unsquashfs -> $DEST (a few minutes) ..."
$SUDO unsquashfs -no-xattrs -d "$DEST" "$TMP_SQ" >/dev/null
$SUDO rm -f "$TMP_SQ"
$SUDO test -d "$DEST/usr/lib/python3.12/site-packages/pygame" || {
    echo "extraction finished but knulli pygame missing — unexpected image layout" >&2; exit 1; }
echo "knulli rootfs ready at $DEST"
