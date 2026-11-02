#!/usr/bin/env python3
"""Bridge a physical USB/Bluetooth gamepad (plugged into the Mac) into the
GrainBrick VM's emulated `retrogame_joypad`.

Lima/Virtualization.framework offers no USB passthrough for gamepads, so the
pad is read on macOS (pygame-ce -> SDL -> Game Controller framework) and
translated into virtual_joypad.py FIFO commands over one persistent ssh pipe.
Buttons/hat are edge-triggered, so held inputs stay held in the VM and the
app's own repeat profiles do the rest — navigation feels native.

Usage:  knulli-vm bridge          (runs this with the configured VM name)
"""
import os
import subprocess
import sys
import time

os.environ.setdefault("PYGAME_HIDE_SUPPORT_PROMPT", "1")
# Do NOT set SDL_VIDEODRIVER=dummy: on macOS, SDL enumerates gamepads through
# the Game Controller framework, whose connect callbacks run on the Cocoa run
# loop — the dummy video driver never pumps that loop, so a pad that was
# already plugged in stayed invisible (get_count()==0 forever) until an
# unplug/replug generated a fresh hotplug event. The default cocoa driver
# without any window is headless enough, and pygame.event.pump() then
# attaches already-connected pads within ~1 s of startup.
import pygame.joystick  # noqa: E402
import pygame.display   # noqa: E402
import pygame          # noqa: E402

VM = sys.argv[1] if len(sys.argv) > 1 else "grainbrick"
FIFO = "/tmp/joypad.fifo"
STICK_DZ = 0.5

# Button indices measured from the user's pad by a full press sweep
# (2026-11-02): a USB pad spoofing Microsoft 045E:028E (Xbox 360) but
# presenting a nonstandard raw HID order — 17 buttons, 6 axes, 0 hats,
# dpad as plain buttons. Do NOT assume the SDL/Xbox standard order here:
# that assumption shipped wrong dpad/button mapping until measured.
# Axes: 0/1 = left stick, 3/4 = right stick, 2/5 = analog LT/RT (they
# move together with digital buttons 13/16 — ignore the axes, the
# buttons carry the edge).
BUTTON_MAP = {
    0: "A", 5: "B", 1: "X", 6: "Y",          # face (bottom, right, left, top)
    11: "L1", 14: "R1", 13: "L2", 16: "R2",  # shoulders
    4: "SELECT", 3: "START", 12: "MODE",     # small buttons (Guide -> MODE)
}
# dpad arrives as buttons, not a hat (order probed: press up/down/left/
# right hit 10/7/8/9; diagonals were exactly the pairwise sums).
DPAD_BUTTONS = {10: "up", 7: "down", 8: "left", 9: "right"}
HAT_DIR = {"up": (0, 1), "down": (0, -1), "left": (-1, 0), "right": (1, 0)}


class FifoPipe:
    """One long-lived `sudo tee FIFO` in the guest; lines written to its
    stdin arrive at virtual_joypad.py. Reconnects if ssh drops."""

    def __init__(self):
        self.proc = None

    def send(self, line):
        if self.proc is None or self.proc.poll() is not None:
            self.proc = subprocess.Popen(
                ["limactl", "shell", VM, "--", "sudo", "tee", FIFO],
                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL)
        try:
            self.proc.stdin.write((line + "\n").encode())
            self.proc.stdin.flush()
        except (BrokenPipeError, ValueError):
            self.proc = None


def read_hat(j, latched):
    """Logical dpad direction: real hat first, then dpad-as-buttons, then stick.

    latched is a persistent list of currently-held dpad button indices in
    press order; the NEWEST held one wins on diagonals (a plain scan order
    would pin the dpad to whichever index happens to be lowest)."""
    try:
        hx, hy = j.get_hat(0)
        if (hx, hy) != (0, 0):
            for name, (dx, dy) in HAT_DIR.items():
                if (hx, hy) == (dx, dy):
                    return name
    except Exception:
        pass
    held = [b for b in DPAD_BUTTONS if b < j.get_numbuttons() and j.get_button(b)]
    latched[:] = [b for b in latched if b in held]          # released
    latched += [b for b in held if b not in latched]        # newly pressed
    if latched:
        return DPAD_BUTTONS[latched[-1]]
    if j.get_numaxes() >= 2:
        lx, ly = j.get_axis(0), j.get_axis(1)  # ly: -1 = up
        if abs(lx) > STICK_DZ and abs(lx) >= abs(ly):
            return "left" if lx < 0 else "right"
        if abs(ly) > STICK_DZ:
            return "up" if ly < 0 else "down"
    return None


def poll_pad(j, pipe, held_btn, sent_hat, latched):
    for b, name in BUTTON_MAP.items():
        if b >= j.get_numbuttons():
            continue
        down = bool(j.get_button(b))
        if down and b not in held_btn:
            pipe.send(f"hold {name}")
            held_btn.add(b)
        elif not down and b in held_btn:
            pipe.send(f"release {name}")
            held_btn.discard(b)
    hat = read_hat(j, latched)
    if hat != sent_hat:
        pipe.send(f"holdhat {hat}" if hat else "holdhat none")
        sent_hat = hat
    return sent_hat


def main():
    pygame.display.init()
    pygame.joystick.init()
    pipe = FifoPipe()
    print("waiting for a gamepad (any USB/BT pad the Mac sees)...", flush=True)
    j = None
    held_btn, sent_hat, latched = set(), None, []
    while True:
        pygame.event.pump()  # let SDL/GCController deliver connect events
        if j is None:
            if pygame.joystick.get_count() == 0:
                time.sleep(0.2)
                continue
            j = pygame.joystick.Joystick(0)
            j.init()
            print(f"connected: {j.get_name()!r} "
                  f"({j.get_numbuttons()} btn, {j.get_numhats()} hat, "
                  f"{j.get_numaxes()} axes)", flush=True)
            held_btn, sent_hat, latched = set(), None, []
        try:
            sent_hat = poll_pad(j, pipe, held_btn, sent_hat, latched)
        except Exception:  # device unplugged mid-poll
            print("pad disconnected", flush=True)
            for b in held_btn:
                pipe.send(f"release {BUTTON_MAP[b]}")
            pipe.send("holdhat none")
            j, held_btn, sent_hat, latched = None, set(), None, []
            continue
        time.sleep(0.012)  # ~80 Hz: below SDL poll interval, cheap over ssh


if __name__ == "__main__":
    main()
