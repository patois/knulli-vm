#!/usr/bin/env python3
"""Keyboard -> joypad mapper for the KNULLI VM display (:1).

Taps *global* X11 key events with the RECORD extension (the app keeps
receiving them too — nothing is swallowed) and translates them into
retrogame_joypad commands on the virtual_joypad FIFO. Needs python3-xlib
in the *guest* (apt install python3-xlib) and write access to the FIFO
(run it with sudo, like virtual_joypad.py).

Resilience (learned the hard way — a silent deaf keyboard is miserable to
debug over VNC):
  * FIFO writes happen on a dedicated writer thread with O_NONBLOCK. The
    RECORD callback must never block: while it stalls, X events pile up in
    the connection buffer until the server kills the client, and the
    keyboard then does nothing forever with no error anywhere.
  * record_enable_context is wrapped in a reconnect loop, so an X server
    restart (or an overflow disconnect) self-heals instead of going deaf.
    Held buttons/hat are released across the gap so the pad never sticks.
  * Every mapped key press/release is logged (to /tmp/keymap.log) so the
    next "keys don't work" report has ground truth in one tail.

Default map mirrors the TRIMUI BRICK's physical buttons (see README):

    dpad            W/S/A/D + arrow keys (diagonals combine: W+A -> upleft)
    A  (right)      j                 B  (bottom)   k
    X  (top)        u or x            Y  (left)     i
    L1 / L2         q / z             R1 / R2       e / c
    SELECT          BackSpace         START         Enter or space
    MENU (logo)     m                 -> BTN_MODE

  The Brick has no analog sticks, so L3/R3 keys do not exist; Z/C drive the
  rear L2/R2 triggers instead. FN/F1/F2 are NOT joystick events on the real
  device either — they are a gpio-keys keyboard; here the raw VNC keyboard
  already delivers F1/F2 to the app as plain key presses, and FN (a
  hotkey-mode toggle for OS shortcuts) has no meaning for apps.
"""
import os
import queue
import sys
import threading
import time

from Xlib import X, XK, display
from Xlib.ext import record
from Xlib.protocol import rq

FIFO = os.environ.get("JOYPAD_FIFO", "/tmp/joypad.fifo")


def log(msg):
    print(f"keymapd: {msg}", flush=True)


# keysym -> ("btn", NAME) or ("hat", DIR); names = virtual_joypad device
# vocabulary (A B X Y L1 R1 L2 R2 SELECT START MODE TAB-/TAB+)
KEYMAP = {
    # dpad (two hands' worth, like the device's physical dpad)
    XK.XK_w: ("hat", "up"), XK.XK_s: ("hat", "down"),
    XK.XK_a: ("hat", "left"), XK.XK_d: ("hat", "right"),
    XK.XK_Up: ("hat", "up"), XK.XK_Down: ("hat", "down"),
    XK.XK_Left: ("hat", "left"), XK.XK_Right: ("hat", "right"),
    # face buttons, by the Brick's printed letters
    XK.XK_j: ("btn", "A"), XK.XK_k: ("btn", "B"),
    XK.XK_u: ("btn", "X"), XK.XK_x: ("btn", "X"),
    XK.XK_i: ("btn", "Y"),
    # shoulder buttons: L1/R1 top row, L2/R2 bottom row (no sticks on the
    # Brick, so z/c are free for the rear triggers)
    XK.XK_q: ("btn", "L1"), XK.XK_e: ("btn", "R1"),
    XK.XK_z: ("btn", "L2"), XK.XK_c: ("btn", "R2"),
    # small buttons
    XK.XK_Return: ("btn", "START"), XK.XK_space: ("btn", "START"),
    XK.XK_BackSpace: ("btn", "SELECT"), XK.XK_m: ("btn", "MODE"),
    # F1/F2 are joystick TAB-/TAB+ on the real device (the driver maps the
    # two bottom keys onto stick-click codes), so mirror them here too
    XK.XK_F1: ("btn", "TAB-"), XK.XK_F2: ("btn", "TAB+"),
}

# Commands queue to the writer thread; send() itself must never block.
_cmdq = queue.Queue()


def send(line):
    _cmdq.put(line)


def writer_loop():
    """Sole writer to the joypad FIFO, off the X event path.

    Blocking os.open(O_WRONLY) waits for a reader (virtual_joypad) and
    os.write waits on a full pipe buffer — either one, run inline in the
    RECORD callback, freezes X event delivery and eventually gets this
    client disconnected by the X server. O_NONBLOCK + retry makes the
    worst case here 'a command is delayed', never 'the keyboard dies'.
    ENXIO = no reader yet (joypad restarting), ENOENT = FIFO was deleted,
    EPIPE/ENODEV = reader died; all heal by reopening, so retry forever.
    """
    fd = None
    warned = False
    while True:
        data = (_cmdq.get() + "\n").encode()
        while True:
            try:
                if fd is None:
                    fd = os.open(FIFO, os.O_WRONLY | os.O_NONBLOCK)
                    warned = False
                os.write(fd, data)
                break
            except OSError as e:
                if fd is not None:
                    try:
                        os.close(fd)
                    except OSError:
                        pass
                    fd = None
                if not warned:
                    log(f"cannot write {FIFO} ({e}); retrying until the joypad is back")
                    warned = True
                time.sleep(0.2)


# Hold floors, measured against GrainBrick (empirically bracketed 2026-11-02):
#  * BUTTONS are event-driven (JOYBUTTONDOWN/UP off the pygame queue): 80 ms
#    FIFO taps register fine. The floor only needs to outlast XKB auto-repeat
#    (a held key must stay ONE hold, not machine-gun taps) and VNC
#    press+release pairs landing in the same frame.
#  * HAT steps are debounced by the app: 150 ms hat taps vanish, 200 ms
#    register (horizontal_hold_start/repeat logic in InputManager). 220 ms
#    with margin. The old single 350 ms floor over-penalised both.
BTN_HOLD = 0.12
HAT_HOLD = 0.22


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
        self.last = None

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

        self.delayed.schedule(d, fire, HAT_HOLD)

    def reset(self):
        for d in list(self.pressed):
            self.delayed.cancel(d)
        self.pressed = []
        self.update()

    def update(self):
        p = set(self.pressed)
        if not p:
            pos = "none"
            send("holdhat none")
        else:
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
            pos = "".join(v)
            send("holdhat " + pos)
        if pos != self.last:
            log(f"hat {pos}")
            self.last = pos


def tap_once(hat, held, btn_delayed):
    """One RECORD tap on the current X connection. Blocks in
    record_enable_context until the connection dies (server restart,
    buffer overflow), then returns so the caller can reconnect."""
    disp = display.Display()
    if not disp.has_extension("RECORD"):
        sys.exit("keymapd: X RECORD extension missing")

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
                    log(f"btn {target} down")
                    send(f"hold {target}")
            elif target in held:
                def fire(t=target):
                    held.discard(t)
                    log(f"btn {t} up")
                    send(f"release {t}")
                btn_delayed.schedule(target, fire, BTN_HOLD)
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
    log(f"mapping keyboard on {disp.get_display_name()} -> {FIFO}")
    disp.record_enable_context(ctx, handler)
    log("RECORD context ended (X connection closed)")


def main():
    threading.Thread(target=writer_loop, daemon=True).start()
    hat = HatState()
    held = set()
    btn_delayed = Delayed()
    while True:
        try:
            tap_once(hat, held, btn_delayed)
        except KeyboardInterrupt:
            sys.exit(0)
        except SystemExit:
            raise
        except Exception as e:
            log(f"X error: {e}")
        # Whatever just happened: never leave the pad in a held state, and
        # drop key tracking that may have missed releases during the gap.
        for t in list(held):
            btn_delayed.cancel(t)
            send(f"release {t}")
        held.clear()
        hat.reset()
        # Do NOT reconnect by calling display.Display() again in this
        # process: after a connection dies, python-xlib carries dead state
        # (observed against a replaced X server: a fresh process maps
        # instantly, the reconnecting one loops forever with "'type' object
        # does not support item assignment"). Re-exec ourselves instead —
        # a clean interpreter is the only reconnect that has ever worked.
        log("restarting interpreter in 1s ...")
        time.sleep(1)
        os.execv(sys.executable, [sys.executable, os.path.abspath(__file__)])


if __name__ == "__main__":
    main()
