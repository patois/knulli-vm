# knulli-vm

Run **apps built for the TrimUI Brick / KNULLI Linux** (like
[GrainBrick](https://github.com/ETRNLIAM/GrainBrick)) directly on your Mac,
inside the *actual* KNULLI userspace taken from a real knulli device image.

KNULLI images are Allwinner/Rockchip device firmware and cannot boot under
Virtualization.framework. This project boots a stock Ubuntu 24.04 arm64 Lima
VM and **chroots the OS squashfs from the knulli image** instead — the app
then runs against knulli's own CPython 3.12, knulli's system pygame, knulli's
ALSA stack, and knulli's own `/usr/bin/pygame` launcher (the same one
EmulationStation execs for pygame ports on the device), installed under
`/userdata/roms/ports/` exactly like on hardware.

## What this is / isn't

- **Not included in git** (created at install time, `.gitignore`d): the knulli
  image, the extracted rootfs, SDL2 sources/builds, app archives, venvs. The
  repo contains only the tooling.
- One deliberate substitution: knulli's SDL2 has a single video driver,
  `mali` (the device's GPU blob; the image ships no X11/kmsdrm/framebuffer).
  The installer builds stock **SDL2 2.32.x with X11** and shadows only that
  soname via `LD_LIBRARY_PATH` (`/opt/sdl2-x11`). Knulli keeps its own glibc,
  libasound, SDL2_ttf/image/mixer — and the built SDL satisfies the ≥2.32.8
  floor knulli's pygame enforces ("SDL downgrade" check).
- The app itself is never modified; run as distributed.

## Requirements

- Apple Silicon Mac, `brew install lima`, `python3`, `curl`.

## Install

```sh
./install.sh                    # downloads the latest knulli image for the
                                # TrimUI Brick (knulli-cfw/distribution)
./install.sh --image ./knulli-a133-trimui-brick-...img      # local image file
./install.sh --image-url https://.../knulli-....img.gz      # specific build
./install.sh --image-device knulli-h700-rg-cubexx           # other devices
./install.sh --app ~/Downloads/GrainBrick_beta_1.0_TrimUI_Brick_KNULLI.zip
```

The installer: creates the Lima VM (`vm/knulli.yaml`) → deploys guest scripts
→ fetches/verifies (sha256) the image → extracts the OS squashfs
(`lib/guest/extract_knulli.sh`; the GPT first-LBA sits at partition-entry
offset **32**, a classic parsing trap) → builds the SDL2 x11 compat library
→ installs any `--app` you pass.

## Using it

```sh
./knulli-vm start              # start services + default app (e.g. GrainBrick)
open vnc://localhost:5901      # macOS Screen Sharing; password 'knulli'
./knulli-vm status             # VM / services / app / apps
./knulli-vm screenshot         # grab the display to a PNG
./knulli-vm stop
```

**Apps** (install time or later; zip, directory, or URL):

```sh
./knulli-vm app add <zip|dir|url> [--name N] [--cmd C] [--default]
./knulli-vm app list            # knulli-vm app default NAME | app rm NAME
./knulli-vm start someapp
```

Launch-script auto-detection: `gb_launch.py` → `main.py` → `run.sh` → a lone
`*.sh` (override with `--cmd`). Apps land in
`<rootfs>/userdata/roms/ports/<name>/` and are exec'd the way knulli's
EmulationStation does it (`cd <appdir> && /usr/bin/pygame <script>`).

**Input.** The VM has an emulated `retrogame_joypad` — a uinput replica of
knulli's `rocknix-joypad` kernel driver (same device name GrainBrick checks
for, same evdev codes/hat axes), so it's indistinguishable from the onboard
pad at the SDL layer:

```sh
./knulli-vm input "hat down 150"        # tap; holdhat down / holdhat none for held
./knulli-vm input "press SOUTH"
./knulli-vm bridge                      # physical USB/BT pad plugged into the Mac
```

`bridge` reads the pad via pygame-ce (macOS Game Controller framework) and
streams held button/dpad states into the VM over one ssh pipe — the app's own
repeat profiles then behave natively. (USB *passthrough* isn't possible:
Lima/vz exposes no USB, and Virtualization.framework's gamepad support is nil.)

**Audio.** Output is currently silent (`snd-dummy`) — see below.

## Layout

```
install.sh              one-shot installer (image/VM/rootfs/SDL/apps)
knulli-vm               day-to-day CLI (start/stop/app/input/bridge/...)
vm/knulli.yaml          Lima template (Ubuntu 24.04 arm64, vz)
lib/guest/              deployed into guest ~/knulli-vm (chroot, joypad, launcher,
                        knulli-image extractor, SDL2 x11 builder)
lib/host/pad_bridge.py  macOS gamepad bridge
state/                  per-VM config + app registry (gitignored)
downloads/              images, SDL tarballs, app zips (gitignored)
```

## Troubleshooting

- **`mountpoint`/`df` hang in the guest (100% sys spin)** — stacked duplicate
  bind-mounts. The `mountpoint -q` guards in `knulli-chroot.sh` are
  load-bearing; never remove them. Recovery: `sudo umount -l <path>` in a loop
  by explicit path.
- **"Dynamic linking causes SDL downgrade"** — `/opt/sdl2-x11` must hold
  SDL ≥ 2.32.8; re-run `lib/guest/build_sdl2_x11.sh`.
- **App stops reacting after restarting the joypad** — recreating the uinput
  device requires restarting the app (SDL delivers events only for opened
  joysticks): `knulli-vm stop && knulli-vm start`.
- **VNC shows an auth error before the password prompt** — modern macOS
  Screen Sharing refuses auth-less servers; always start x11vnc with
  `-passwd`.
- **`pkill -f <pattern>` from a shell whose cmdline contains the pattern kills
  your own ssh session** — use `pattern[.]ext`.
- `limactl start` may stall on lima's optional containerd step; the VM is
  usable regardless — `limactl shell <vm>`.

## Status / known limits

- Video: Xvfb 1280×720 → VNC. Audio: **silent** (`snd-dummy`); piping guest
  ALSA to the Mac is a work in progress. No mic/USB audio (no such hardware).
- Apps run as root in the chroot (knulli's own model); the VM is the sandbox —
  treat downloaded images/apps as untrusted accordingly.
