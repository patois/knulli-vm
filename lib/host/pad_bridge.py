#!/usr/bin/env python3
"""Bridge a physical USB/Bluetooth gamepad (plugged into the Mac) into the
GrainBrick VM's emulated `retrogame_joypad`.

Lima/Virtualization.framework offers no USB passthrough for gamepads, so the
pad is read on macOS (pygame-ce -> SDL -> Game Controller framework) and
translated into virtual_joypad.py FIFO commands over one persistent ssh pipe.
Buttons/hat are edge-triggered, so held inputs stay held in the VM and the
app's own repeat profiles do the rest — navigation feels native.

Usage:  ~/projects/priv/grainbrick-run/padenv/bin/python \
            ~/projects/priv/grainbrick-run/vm/pad_bridge.py [vm-name]
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

# SDL standard game-controller button indices (Xbox layout, what virtually
# every USB/BT pad reports through the Game Controller framework) mapped to
# the TrimUI Brick button names the app uses.
BUTTON_MAP = {
    0: "SOUTH", 1: "EAST", 2: "WEST", 3: "NORTH",
    4: "TL", 5: "TR", 6: "SELECT", 7: "START", 8: "MODE",
    9: "THUMBL", 10: "THUMBR",
}
# Some HID pads report the dpad as extra buttons instead of a hat:
HAT_BUTTONS = {12: "up", 13: "down", 14: "left", 15: "right"}
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
            self._sent_hat = None  # fresh pipe: VM state unknown, resync
        try:
            self.proc.stdin.write((line + "\n").encode())
            self.proc.stdin.flush()
        except (BrokenPipeError, ValueError):
            self.proc = None


def read_hat(j):
    """Logical dpad direction: real hat first, then dpad-as-buttons, then stick."""
    try:
        hx, hy = j.get_hat(0)
        for name, (dx, dy) in HAT_DIR.items():
            if (hx, hy) == (dx, dy):
                return name
    except Exception:
        pass
    for b, name in HAT_BUTTONS.items():
        if b < j.get_numbuttons() and j.get_button(b):
            return name
    if j.get_numaxes() >= 2:
        lx, ly = j.get_axis(0), j.get_axis(1)  # ly: -1 = up
        if abs(lx) > STICK_DZ and abs(lx) >= abs(ly):
            return "left" if lx < 0 else "right"
        if abs(ly) > STICK_DZ:
            return "up" if ly < 0 else "down"
    return None


def poll_pad(j, pipe, held_btn, sent_hat):
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
    hat = read_hat(j)
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
    held_btn, sent_hat = set(), None
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
            held_btn, sent_hat = set(), None
        try:
            sent_hat = poll_pad(j, pipe, held_btn, sent_hat)
        except Exception:  # device unplugged mid-poll
            print("pad disconnected", flush=True)
            for b in held_btn:
                pipe.send(f"release {BUTTON_MAP[b]}")
            pipe.send("holdhat none")
            j, held_btn, sent_hat = None, set(), None
            continue
        time.sleep(0.012)  # ~80 Hz: below SDL poll interval, cheap over ssh


if __name__ == "__main__":
    main()
