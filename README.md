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
- Xcode Command Line Tools (`xcrun swiftc`) for the small host audio player;
  everything still installs without it, you just get no sound.

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
→ sets up guest→Mac audio routing → builds the host audio player → installs
any `--app` you pass. Re-running it is safe: slow steps (VM, extraction,
SDL build) detect existing state and skip.

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

**Keyboard.** While the VNC window has Mac keyboard focus, the keys are
mapped to the pad too (`lib/guest/keymapd.py` taps X11 globally without
grabbing, so the app still sees raw keys if it wants them):

| keys | pad | keys | pad |
|---|---|---|---|
| W A S D / arrows | dpad (diagonals combine) | Q / E | L / R |
| J / K | A (south) / B (east) | Enter, space | START |
| U / I | X (west) / Y (north) | BackSpace | SELECT |
| Z / C | L3 / R3 | m | MODE |

Fast taps are stretched to ≥350 ms — the app samples the pad slowly and
sub-frame blips vanish — and auto-repeat is absorbed as a held key.

**Audio.** The guest has no sound device, so the chroot's ALSA `default` is
routed into a `snd-aloop` loopback card (`lib/guest/setup_audio.sh`) and
`knulli-vm audio start` (run automatically by `start`) captures the far end
over ssh into `bin/audioplay`, a tiny CoreAudio sink on the Mac. Two details
that look wrong but are right: the aloop cables are *cross-wired* (default
writes device 0 playback → host reads device 1 capture), and `snd-dummy`
occupies card 0 on purpose because apps like GrainBrick open the mic as a
hardcoded `hw:1,0` — card 1 must be the loopback card.

## Layout

```
install.sh              one-shot installer (image/VM/rootfs/SDL/audio/apps)
knulli-vm               day-to-day CLI (start/stop/app/input/bridge/audio/...)
vm/knulli.yaml          Lima template (Ubuntu 24.04 arm64, vz)
lib/guest/              deployed into guest ~/knulli-vm: chroot entry, virtual
                        joypad, keymapd (keyboard->pad), focusd, launcher,
                        audio routing, knulli-image extractor, SDL2 x11 builder
lib/host/pad_bridge.py  macOS gamepad bridge
lib/host/audioplay.swift CoreAudio sink for guest audio (built to bin/)
state/                  per-VM config + app registry (gitignored, holds VNC pass)
downloads/              images, SDL tarballs, app zips (gitignored)
bin/                    built host binaries (gitignored)
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
- **App silent, or dies/ignores input a few seconds in** — its ALSA stream
  underruns because nothing is draining the loopback card. `knulli-vm start`
  starts the audio pipe *before* the app for exactly this reason; if you
  killed the pipe mid-session, `knulli-vm audio start` (or restart the app).
- **`arecord` says "Device or resource busy"** — an orphaned capture from a
  previous session holds the loopback: `knulli-vm audio stop` then `start`.
- **Keyboard does nothing on the VNC display** — no window manager exists, so
  `focusd.sh` (started by the launcher) keeps focus on the app window; check
  `pgrep -f focusd` and `/tmp/focusd.log` in the guest.
- **VNC shows an auth error before the password prompt** — modern macOS
  Screen Sharing refuses auth-less servers; always start x11vnc with
  `-passwd`.
- **`pkill -f <pattern>` from a shell whose cmdline contains the pattern kills
  your own ssh session** — use `pattern[.]ext`.
- `limactl start` may stall on lima's optional containerd step; the VM is
  usable regardless — `limactl shell <vm>`.

## Status / known limits

- Video: Xvfb 1280×720 → VNC. Audio out: works (loopback → Mac speakers,
  48 kHz stereo). Mic in: apps open `hw:1,0` and get a *silent* loopback
  capture — there is no host-mic→guest pipe yet (would be the mirror of the
  playback path; `snd-aloop`'s free cross-cable is already there for it).
- Apps run as root in the chroot (knulli's own model); the VM is the sandbox —
  treat downloaded images/apps as untrusted accordingly.
