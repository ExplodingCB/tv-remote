#!/usr/bin/env python3
"""Line-delimited JSON bridge between the ATV Remote app and pyatv.

The Swift app launches this script and writes one JSON command per line to
stdin. Replies (matched by "id") and unsolicited events are written as one
JSON object per line to stdout.
"""

import asyncio
import json
import logging
import os
import sys
from pathlib import Path

import pyatv
from pyatv import interface
from pyatv.const import (
    InputAction,
    KeyboardFocusState,
    OperatingSystem,
    PowerState,
    Protocol,
    TouchAction,
)
from pyatv.storage.file_storage import FileStorage

logging.basicConfig(level=logging.WARNING, stream=sys.stderr)
# pyatv "knocks" on hosts to wake them while scanning; unreachable ones just
# leave noisy unretrieved-task errors behind.
logging.getLogger("asyncio").setLevel(logging.CRITICAL)

SUPPORT_DIR = Path(
    os.environ.get(
        "ATV_REMOTE_SUPPORT_DIR",
        Path.home() / "Library" / "Application Support" / "ATV Remote",
    )
)
PAIRING_NAME = os.environ.get("ATV_REMOTE_PAIRING_NAME", "Mac Remote")

# Buttons that accept a single/double/hold InputAction.
ACTION_KEYS = {"up", "down", "left", "right", "select", "menu", "home"}
KEYS = ACTION_KEYS | {
    "play_pause",
    "volume_up",
    "volume_down",
    "top_menu",
    "control_center",
    "guide",
    "screensaver",
    "skip_forward",
    "skip_backward",
    "next",
    "previous",
    "channel_up",
    "channel_down",
}
INPUT_ACTIONS = {
    "single": InputAction.SingleTap,
    "double": InputAction.DoubleTap,
    "hold": InputAction.Hold,
}
TOUCH_PHASES = {
    "press": TouchAction.Press,
    "hold": TouchAction.Hold,
    "release": TouchAction.Release,
}


def is_apple_tv(info):
    """HomePods also run tvOS and advertise Companion, so go by hardware model."""
    raw_model = str(info.raw_model or "")
    if raw_model:
        return raw_model.startswith("AppleTV")
    return info.operating_system == OperatingSystem.TvOS and "HomePod" not in info.model_str


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


class Listener(
    interface.DeviceListener, interface.PowerListener, interface.KeyboardListener
):
    def __init__(self, bridge):
        self.bridge = bridge

    def connection_lost(self, exception):
        self.bridge.atv = None
        emit({"event": "disconnected", "reason": str(exception)})

    def connection_closed(self):
        self.bridge.atv = None
        emit({"event": "disconnected", "reason": None})

    def powerstate_update(self, old_state, new_state):
        emit({"event": "power", "on": new_state == PowerState.On})

    def focusstate_update(self, old_state, new_state):
        emit({"event": "keyboard", "focused": new_state == KeyboardFocusState.Focused})


class Bridge:
    def __init__(self, loop):
        self.loop = loop
        SUPPORT_DIR.mkdir(parents=True, exist_ok=True)
        self.storage = FileStorage(str(SUPPORT_DIR / "pyatv.conf"), loop)
        self.configs = {}
        self.atv = None
        self.device_id = None
        self.pairing = None
        self.listener = Listener(self)
        # Remote input must reach the TV in order, so it goes through one queue.
        self.input_queue = asyncio.Queue()

    # ---- plumbing -------------------------------------------------------

    async def run(self):
        await self.storage.load()
        reader = asyncio.StreamReader()
        await self.loop.connect_read_pipe(
            lambda: asyncio.StreamReaderProtocol(reader), sys.stdin
        )
        worker = self.loop.create_task(self.input_worker())
        emit({"event": "ready", "pyatv": pyatv.const.__version__})

        while line := await reader.readline():
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            cmd = msg.get("cmd")
            if cmd in ("key", "touch", "click", "text"):
                self.input_queue.put_nowait(msg)
            else:
                self.loop.create_task(self.dispatch(msg))

        # stdin closed: the app quit.
        worker.cancel()
        await self.cmd_pair_cancel({})
        await self.disconnect({})

    async def input_worker(self):
        while True:
            msg = await self.input_queue.get()
            await self.dispatch(msg)

    async def dispatch(self, msg):
        handler = getattr(self, "cmd_" + str(msg.get("cmd")), None)
        reply = {"id": msg.get("id")}
        try:
            if handler is None:
                raise ValueError(f"unknown command {msg.get('cmd')}")
            reply.update(await handler(msg) or {})
            reply["ok"] = True
        except Exception as ex:  # pylint: disable=broad-except
            logging.warning("command %s failed: %r", msg.get("cmd"), ex)
            reply.update(
                ok=False, error=str(ex) or type(ex).__name__, error_type=type(ex).__name__
            )
        if reply["id"] is not None:
            emit(reply)

    def require_atv(self):
        if self.atv is None:
            raise RuntimeError("Not connected to an Apple TV")
        return self.atv

    # ---- discovery & pairing -------------------------------------------

    async def cmd_scan(self, msg):
        # The app passes hosts it found via the system's Bonjour service;
        # pyatv's own multicast scan is only a fallback.
        confs = await pyatv.scan(
            self.loop,
            timeout=msg.get("timeout", 4),
            hosts=msg.get("hosts") or None,
            storage=self.storage,
        )
        devices = []
        for conf in confs:
            companion = conf.get_service(Protocol.Companion)
            if companion is None:
                continue
            if not is_apple_tv(conf.device_info):
                continue
            self.configs[conf.identifier] = conf
            devices.append(
                {
                    "id": conf.identifier,
                    "name": conf.name,
                    "address": str(conf.address),
                    "model": conf.device_info.model_str,
                    "paired": companion.credentials is not None,
                }
            )
        devices.sort(key=lambda d: d["name"].lower())
        return {"devices": devices}

    async def config_for(self, device_id, host=None):
        conf = self.configs.get(device_id)
        if conf is None:
            confs = await pyatv.scan(
                self.loop,
                identifier=None if host else device_id,
                hosts=[host] if host else None,
                timeout=5,
                storage=self.storage,
            )
            confs = [c for c in confs if device_id in c.all_identifiers]
            if not confs:
                raise RuntimeError("Apple TV not found on the network")
            conf = self.configs[device_id] = confs[0]
        return conf

    async def cmd_pair_begin(self, msg):
        await self.cmd_pair_cancel({})
        conf = await self.config_for(msg["device"], msg.get("host"))
        self.pairing = await pyatv.pair(
            conf, Protocol.Companion, self.loop, storage=self.storage, name=PAIRING_NAME
        )
        await self.pairing.begin()
        return {}

    async def cmd_pair_pin(self, msg):
        if self.pairing is None:
            raise RuntimeError("Pairing was not started")
        self.pairing.pin(int(msg["pin"]))
        try:
            await self.pairing.finish()
            if not self.pairing.has_paired:
                raise RuntimeError("Pairing failed, check the code and try again")
            await self.storage.save()
        finally:
            await self.cmd_pair_cancel({})
        return {}

    async def cmd_pair_cancel(self, _msg):
        if self.pairing is not None:
            pairing, self.pairing = self.pairing, None
            try:
                await pairing.close()
            except Exception:  # pylint: disable=broad-except
                pass
        return {}

    async def cmd_forget(self, msg):
        conf = await self.config_for(msg["device"])
        settings = await self.storage.get_settings(conf)
        settings.protocols.companion.credentials = None
        await self.storage.save()
        conf.get_service(Protocol.Companion).credentials = None
        return {}

    # ---- connection -----------------------------------------------------

    async def cmd_connect(self, msg):
        await self.disconnect({})
        conf = await self.config_for(msg["device"], msg.get("host"))
        # Only Companion is needed for remote control; skipping the rest keeps
        # connecting fast and avoids needing AirPlay credentials.
        for service in conf.services:
            service.enabled = service.protocol == Protocol.Companion
        atv = await pyatv.connect(conf, self.loop, storage=self.storage)
        atv.listener = self.listener
        atv.power.listener = self.listener
        atv.keyboard.listener = self.listener
        self.atv, self.device_id = atv, conf.identifier

        reply = {"power": None, "keyboard": False}
        try:
            reply["power"] = atv.power.power_state == PowerState.On
        except Exception:  # pylint: disable=broad-except
            pass
        try:
            reply["keyboard"] = atv.keyboard.text_focus_state == KeyboardFocusState.Focused
        except Exception:  # pylint: disable=broad-except
            pass
        return reply

    async def disconnect(self, _msg):
        if self.atv is not None:
            atv, self.atv = self.atv, None
            atv.listener = None
            for pending in atv.close():
                try:
                    await pending
                except Exception:  # pylint: disable=broad-except
                    pass
        return {}

    cmd_disconnect = disconnect

    # ---- remote input ---------------------------------------------------

    async def cmd_key(self, msg):
        rc = self.require_atv().remote_control
        key = msg["key"]
        if key not in KEYS:
            raise ValueError(f"unknown key {key}")
        if key in ("volume_up", "volume_down"):
            await getattr(self.require_atv().audio, key)()
            return {}
        method = getattr(rc, key)
        if key in ACTION_KEYS:
            await method(INPUT_ACTIONS[msg.get("action", "single")])
        else:
            await method()
        return {}

    async def cmd_touch(self, msg):
        await self.require_atv().touch.action(
            int(msg["x"]), int(msg["y"]), TOUCH_PHASES[msg["phase"]]
        )
        return {}

    async def cmd_click(self, msg):
        await self.require_atv().touch.click(INPUT_ACTIONS[msg.get("action", "single")])
        return {}

    async def cmd_power(self, msg):
        power = self.require_atv().power
        state = msg.get("state", "toggle")
        if state == "toggle":
            state = "off" if power.power_state == PowerState.On else "on"
        await (power.turn_off() if state == "off" else power.turn_on())
        return {"on": state == "on"}

    async def cmd_text(self, msg):
        keyboard = self.require_atv().keyboard
        op = msg.get("op", "set")
        if op == "get":
            return {"text": await keyboard.text_get() or ""}
        if op == "clear":
            await keyboard.text_clear()
        elif op == "append":
            await keyboard.text_append(msg["text"])
        else:
            await keyboard.text_set(msg["text"])
        return {}


def main():
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    try:
        loop.run_until_complete(Bridge(loop).run())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
