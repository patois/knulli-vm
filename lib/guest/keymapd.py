#!/usr/bin/env python3
"""Keyboard -> joypad mapper for the KNULLI VM display (:1).

Taps *global* X11 key events with the RECORD extension (the app keeps
receiving them too — nothing is swallowed) and translates them into
retrogame_joypad commands on the virtual_joypad FIFO. Needs python3-xlib
in the *guest* (apt install python3-xlib) and write access to the FIFO
(run it with sudo, like virtual_joypad.py).

Default map (keyboard is not grabbed, so both paths work at once):
  W/S/A/D + arrows   dpad (diagonals by combining, e.g. W+A -> upleft)
  J K U I            A(south) B(east) X(west) Y(north)
  Q E                L / R
  Enter              START        BackSpace  SELECT      m  MODE
  Z C                stick clicks L3 / R3
"""
import os
import sys
import threading
import time

from Xlib import X, XK, display
from Xlib.ext import record
from Xlib.protocol import rq

FIFO = os.environ.get("JOYPAD_FIFO", "/tmp/joypad.fifo")

# keysym -> ("btn", NAME) or ("hat", DIR)
KEYMAP = {
    XK.XK_w: ("hat", "up"), XK.XK_s: ("hat", "down"),
    XK.XK_a: ("hat", "left"), XK.XK_d: ("hat", "right"),
    XK.XK_Up: ("hat", "up"), XK.XK_Down: ("hat", "down"),
    XK.XK_Left: ("hat", "left"), XK.XK_Right: ("hat", "right"),
    XK.XK_j: ("btn", "SOUTH"), XK.XK_k: ("btn", "EAST"),
    XK.XK_x: ("btn", "WEST"), XK.XK_i: ("btn", "NORTH"),
    XK.XK_q: ("btn", "TL"), XK.XK_e: ("btn", "TR"),
    XK.XK_Return: ("btn", "START"), XK.XK_space: ("btn", "START"),
    XK.XK_BackSpace: ("btn", "SELECT"), XK.XK_m: ("btn", "MODE"),
    XK.XK_z: ("btn", "THUMBL"), XK.XK_c: ("btn", "THUMBR"),
}

_fd = None


def send(line):
    global _fd
    data = (line + "\n").encode()
    for _ in range(2):
        try:
            if _fd is None:
                _fd = os.open(FIFO, os.O_WRONLY)  # blocks until joypad reads
            os.write(_fd, data)
            return
        except OSError:
            try:
                if _fd is not None:
                    os.close(_fd)
            except OSError:
                pass
            _fd = None
    print(f"keymapd: cannot write {FIFO}", file=sys.stderr)


MIN_HOLD = 0.35  # GrainBrick samples the pad slowly; ~sub-300ms taps vanish


class Delayed:
    """Fire fn(delay) unless cancelled by a re-press first. This both
    enforces MIN_HOLD (fast taps / XTEST press+release become real presses)
    and absorbs XKB auto-repeat (press,release,press,... stays held)."""

    def __init__(self):
        self.timers = {}

    def schedule(self, key, fn, delay):
        self.cancel(key)
        t = threading.Timer(max(0.0, delay), fn)
        self.timers[key] = t
        t.start()

    def cancel(self, key):
        t = self.timers.pop(key, None)
        if t:
            t.cancel()


class HatState:
    """Held direction keys -> one hat position (diagonals included)."""

    def __init__(self):
        self.pressed = []  # directions, most recent last
        self.delayed = Delayed()

    def press(self, d):
        self.delayed.cancel(d)
        if d in self.pressed:
            return
        self.pressed.append(d)
        self.update()

    def release(self, d):
        if d not in self.pressed:
            return

        def fire():
            if d in self.pressed:
                self.pressed.remove(d)
            self.update()

        self.delayed.schedule(d, fire, MIN_HOLD)

    def update(self):
        p = set(self.pressed)
        if not p:
            send("holdhat none")
            return
        v = []
        if "up" in p or "down" in p:
            v.append("up" if "up" in p else "down")
        if "left" in p or "right" in p:
            v.append("left" if "left" in p else "right")
        # for an up/down clash, the most recently pressed wins
        if p >= {"up", "down"}:
            v[0] = "up" if self.pressed.index("up") > self.pressed.index("down") else "down"
        if p >= {"left", "right"} and len(v) > 1:
            v[1] = "left" if self.pressed.index("left") > self.pressed.index("right") else "right"
        send("holdhat " + "".join(v))


def main():
    disp = display.Display()
    if not disp.has_extension("RECORD"):
        sys.exit("keymapd: X RECORD extension missing")

    hat = HatState()
    held = set()
    btn_delayed = Delayed()

    def on_key(event, pressed):
        ks = disp.keycode_to_keysym(event.detail, 0)
        act = KEYMAP.get(ks) or KEYMAP.get(ks | 0x20)  # tolerate case
        if act is None:
            return
        kind, target = act
        if kind == "btn":
            if pressed:
                btn_delayed.cancel(target)
                if target not in held:
                    held.add(target)
                    send(f"hold {target}")
            elif target in held:
                def fire(t=target):
                    held.discard(t)
                    send(f"release {t}")
                btn_delayed.schedule(target, fire, MIN_HOLD)
        else:
            hat.press(target) if pressed else hat.release(target)

    def handler(reply):
        # categories are implementation-flavoured (we get 0 = FromServerTime);
        # just parse whatever data-bearing reply shows up
        data = reply.data
        while data:
            event, data = rq.EventField(None).parse_binary_value(
                data, disp.display, None, None)
            if event.type == X.KeyPress:
                on_key(event, True)
            elif event.type == X.KeyRelease:
                on_key(event, False)

    ctx = disp.record_create_context(
        0, [record.AllClients],
        [{"core_requests": (0, 0), "core_replies": (0, 0),
          "ext_requests": (0, 0, 0, 0), "ext_replies": (0, 0, 0, 0),
          # VNC/XTEST keys arrive as *delivered* core events on this server
          "delivered_events": (X.KeyPress, X.KeyRelease),
          "device_events": (0, 0),
          "errors": (0, 0),
          "client_started": False, "client_died": False}])
    print(f"keymapd: mapping keyboard on {disp.get_display_name()} -> {FIFO}",
          flush=True)
    disp.record_enable_context(ctx, handler)  # blocks, delivers events


if __name__ == "__main__":
    main()
