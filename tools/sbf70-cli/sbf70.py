#!/usr/bin/env python3
"""
Minimal CLI for Sanitas SBF70 (and Beurer BF710 / Silvercrest SBF75 family).

Protocol ported from openScale BeurerSanitasHandler:
  service 0xFFE0 / characteristic 0xFFE1
  start byte 0xE7 (BF710/SBF70); INIT/SET_TIME use alternate low nibbles.

Wake the scale (step on it briefly) before connecting — it sleeps otherwise.

Examples:
  python sbf70.py scan
  python sbf70.py status
  python sbf70.py users
  python sbf70.py history
  python sbf70.py measure --uid 0000000000000065
  python sbf70.py delete-saved --uid 0000000000000065 --yes
  python sbf70.py unknown
  python sbf70.py delete-unknown --index 0 --yes
  python sbf70.py delete-user --uid 0000000000000065 --yes
"""

from __future__ import annotations

import argparse
import asyncio
import json
import struct
import sys
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Any, Optional

from bleak import BleakClient, BleakScanner
from bleak.backends.device import BLEDevice
from bleak.backends.scanner import AdvertisementData

# GATT
SERVICE_UUID = "0000ffe0-0000-1000-8000-00805f9b34fb"
CHAR_UUID = "0000ffe1-0000-1000-8000-00805f9b34fb"

# SBF70 / BF710 family uses high nibble 0xE
START_CMD = 0xE7  # nibble 7 = command
START_INIT = 0xE6  # nibble 6
START_TIME = 0xE9  # nibble 9
START_DISCONNECT = 0xEA  # nibble 10

CMD_USER_ADD = 0x31
CMD_USER_DELETE = 0x32
CMD_USER_LIST = 0x33
CMD_USER_INFO = 0x34
CMD_USER_UPDATE = 0x35
CMD_USER_DETAILS = 0x36
CMD_DO_MEASUREMENT = 0x40
CMD_GET_SAVED_MEASUREMENTS = 0x41
CMD_SAVED_MEASUREMENT = 0x42
CMD_DELETE_SAVED_MEASUREMENTS = 0x43
CMD_GET_UNKNOWN_MEASUREMENTS = 0x46
CMD_UNKNOWN_MEASUREMENT_INFO = 0x47
CMD_DELETE_UNKNOWN_MEASUREMENT = 0x49
CMD_ASSIGN_UNKNOWN_MEASUREMENT = 0x4B
CMD_UNKNOWN_MEASUREMENT = 0x4C
CMD_SET_UNIT = 0x4D
CMD_SCALE_STATUS = 0x4F
CMD_WEIGHT_MEASUREMENT = 0x58
CMD_MEASUREMENT = 0x59
CMD_SCALE_ACK = 0xF0
CMD_APP_ACK = 0xF1

NAME_HINTS = (
    "sanitas sbf70",
    "sbf75",
    "aicdscale1",
    "beurer bf710",
    "bf700",
    "beurer bf700",
    "bf-700",
    "bf-800",
    "beurer bf800",
    "rt-libra",
    "libra-b",
    "libra-w",
)

UNIT_NAMES = {1: "kg", 2: "lb", 4: "st"}


def _u16_be(data: bytes, offset: int) -> int:
    return struct.unpack_from(">H", data, offset)[0]


def _u32_be(data: bytes, offset: int) -> int:
    return struct.unpack_from(">I", data, offset)[0]


def _i32_be(value: int) -> bytes:
    return struct.pack(">I", value & 0xFFFFFFFF)


def kg_from_raw(data: bytes, offset: int) -> float:
    """Weight unit is 50 g."""
    return _u16_be(data, offset) * 50.0 / 1000.0


def percent_from_raw(data: bytes, offset: int) -> float:
    """Percentage unit is 0.1 %."""
    return _u16_be(data, offset) / 10.0


def decode_user_id(data: bytes, offset: int = 0) -> int:
    high = _u32_be(data, offset)
    low = _u32_be(data, offset + 4)
    return (high << 32) | low


def encode_user_id(uid: int) -> bytes:
    return _i32_be(uid >> 32) + _i32_be(uid & 0xFFFFFFFF)


def uid_hex(uid: int) -> str:
    return f"{uid:016X}"


def parse_uid(text: str) -> int:
    text = text.strip().lower().replace(":", "").replace("-", "").replace("0x", "")
    return int(text, 16)


def decode_cstring(data: bytes, offset: int, maxlen: int) -> str:
    chunk = data[offset : offset + maxlen]
    end = chunk.find(b"\x00")
    if end >= 0:
        chunk = chunk[:end]
    return chunk.decode("ascii", errors="replace")


def hexb(data: bytes) -> str:
    return " ".join(f"{b:02X}" for b in data)


def name_matches(name: Optional[str]) -> bool:
    if not name:
        return False
    n = name.lower()
    return any(h in n for h in NAME_HINTS)


@dataclass
class ScaleStatus:
    battery: int
    weight_threshold_kg: float
    fat_threshold: float
    unit: str
    user_exists: bool
    user_ref_weight_exists: bool
    user_measurement_exists: bool
    version: int


@dataclass
class RemoteUser:
    uid: int
    name: str
    year: int
    index: int = 0
    count: int = 0
    # filled by user-details
    birthday: Optional[str] = None
    height_cm: Optional[int] = None
    sex: Optional[str] = None
    activity: Optional[int] = None


@dataclass
class Measurement:
    timestamp: int
    time_iso: str
    weight_kg: float
    impedance: int
    fat_pct: float
    water_pct: float
    muscle_pct: float
    bone_kg: float
    uid: Optional[int] = None

    @classmethod
    def from_payload(cls, buf: bytes, uid: Optional[int] = None) -> Measurement:
        if len(buf) < 16:
            raise ValueError(f"measurement payload too short: {len(buf)} bytes")
        ts = _u32_be(buf, 0)
        return cls(
            timestamp=ts,
            time_iso=datetime.fromtimestamp(ts, tz=timezone.utc).isoformat(),
            weight_kg=round(kg_from_raw(buf, 4), 2),
            impedance=_u16_be(buf, 6),
            fat_pct=round(percent_from_raw(buf, 8), 1),
            water_pct=round(percent_from_raw(buf, 10), 1),
            muscle_pct=round(percent_from_raw(buf, 12), 1),
            bone_kg=round(kg_from_raw(buf, 14), 2),
            uid=uid,
        )


@dataclass
class UnknownMeasurement:
    """Guest / unassigned reading stored in a fixed scale slot."""

    slot: int
    timestamp: int
    time_iso: str
    weight_kg: float
    impedance: int


@dataclass
class SessionResult:
    address: str
    name: Optional[str]
    status: Optional[ScaleStatus] = None
    users: list[RemoteUser] = field(default_factory=list)
    measurements: list[Measurement] = field(default_factory=list)
    live_weights: list[float] = field(default_factory=list)
    live_measurement: Optional[Measurement] = None


class Sbf70Client:
    """Stateful BLE client for the Beurer/Sanitas FFE0/FFE1 protocol (SBF70)."""

    def __init__(self, address: str, *, verbose: bool = False, timeout: float = 30.0):
        self.address = address
        self.verbose = verbose
        self.timeout = timeout
        self._client: Optional[BleakClient] = None
        self._queue: asyncio.Queue[bytes] = asyncio.Queue()
        self._name: Optional[str] = None

    def _log(self, msg: str) -> None:
        if self.verbose:
            print(f"[dbg] {msg}", file=sys.stderr)

    async def connect(self) -> None:
        self._client = BleakClient(self.address, timeout=self.timeout)
        await self._client.connect()
        self._name = self._client.name
        await self._client.start_notify(CHAR_UUID, self._on_notify)
        self._log(f"connected to {self.address} ({self._name})")

    async def disconnect(self) -> None:
        if self._client and self._client.is_connected:
            try:
                await self._write(bytes([START_DISCONNECT, 0x02]))
            except Exception:
                pass
            try:
                await self._client.stop_notify(CHAR_UUID)
            except Exception:
                pass
            await self._client.disconnect()
        self._client = None

    async def __aenter__(self) -> Sbf70Client:
        await self.connect()
        return self

    async def __aexit__(self, *exc: Any) -> None:
        await self.disconnect()

    def _on_notify(self, _handle: int, data: bytearray) -> None:
        payload = bytes(data)
        self._log(f"← {hexb(payload)}")
        self._queue.put_nowait(payload)

    async def _write(self, data: bytes) -> None:
        assert self._client is not None
        self._log(f"→ {hexb(data)}")
        await self._client.write_gatt_char(CHAR_UUID, data, response=True)

    def _cmd(self, command: int, *params: int) -> bytes:
        return bytes([START_CMD, command, *params])

    async def _ack(self, frame: bytes) -> None:
        # Echo bytes [1..3] after APP_ACK (openScale / wiki).
        if len(frame) < 4:
            return
        await self._write(bytes([START_CMD, CMD_APP_ACK, frame[1], frame[2], frame[3]]))

    async def _wait(
        self,
        predicate,
        *,
        timeout: Optional[float] = None,
        auto_ack: bool = False,
    ) -> bytes:
        deadline = time.monotonic() + (timeout if timeout is not None else self.timeout)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("timed out waiting for scale response")
            frame = await asyncio.wait_for(self._queue.get(), timeout=remaining)
            if auto_ack and len(frame) >= 4 and frame[0] == START_CMD and frame[1] in (
                CMD_USER_INFO,
                CMD_SAVED_MEASUREMENT,
                CMD_WEIGHT_MEASUREMENT,
                CMD_MEASUREMENT,
                CMD_UNKNOWN_MEASUREMENT_INFO,
                CMD_UNKNOWN_MEASUREMENT,
            ):
                await self._ack(frame)
            if predicate(frame):
                return frame

    async def init_session(self) -> None:
        # Drain any stale notifications.
        while not self._queue.empty():
            self._queue.get_nowait()

        await self._write(bytes([START_INIT, 0x01]))
        await self._wait(lambda f: len(f) >= 1 and f[0] == START_INIT)

        unix = int(time.time())
        await self._write(bytes([START_TIME]) + _i32_be(unix))
        # No ACK expected for SET_TIME.
        await asyncio.sleep(0.15)

    async def get_status(self, uid: int = 0) -> ScaleStatus:
        await self._write(self._cmd(CMD_SCALE_STATUS, *encode_user_id(uid)))
        frame = await self._wait(
            lambda f: len(f) >= 12
            and f[0] == START_CMD
            and f[1] == CMD_SCALE_ACK
            and f[2] == CMD_SCALE_STATUS
        )
        # E7 F0 4F <users?> bat thr_w thr_f unit uexist uref umeas ver
        # openScale: data[4]=battery ... data[11]=version  (data[3] unused/pad)
        return ScaleStatus(
            battery=frame[4],
            weight_threshold_kg=frame[5] / 10.0,
            fat_threshold=frame[6] / 10.0,
            unit=UNIT_NAMES.get(frame[7], str(frame[7])),
            user_exists=frame[8] == 0,
            user_ref_weight_exists=frame[9] == 0,
            user_measurement_exists=frame[10] == 0,
            version=frame[11],
        )

    async def list_users(self) -> list[RemoteUser]:
        users: list[RemoteUser] = []
        await self._write(self._cmd(CMD_USER_LIST))

        ack = await self._wait(
            lambda f: len(f) >= 6
            and f[0] == START_CMD
            and f[1] == CMD_SCALE_ACK
            and f[2] == CMD_USER_LIST
        )
        count = ack[4]
        max_users = ack[5]
        self._log(f"user list: {count}/{max_users}")
        if count == 0:
            return users

        while len(users) < count:
            frame = await self._wait(
                lambda f: len(f) >= 16
                and f[0] == START_CMD
                and f[1] == CMD_USER_INFO,
                auto_ack=True,
            )
            total = frame[2]
            current = frame[3]
            uid = decode_user_id(frame, 4)
            name = decode_cstring(frame, 12, 3)
            year = 1900 + frame[15]
            users.append(
                RemoteUser(uid=uid, name=name, year=year, index=current, count=total)
            )
            self._log(f"user {current}/{total}: {name} ({year}) uid={uid_hex(uid)}")

        return users

    async def user_details(self, uid: int) -> RemoteUser:
        await self._write(self._cmd(CMD_USER_DETAILS, *encode_user_id(uid)))
        frame = await self._wait(
            lambda f: len(f) >= 12
            and f[0] == START_CMD
            and f[1] == CMD_SCALE_ACK
            and f[2] == CMD_USER_DETAILS
        )
        if frame[3] != 0:
            raise RuntimeError(f"USER_DETAILS failed status={frame[3]}")
        name = decode_cstring(frame, 4, 3)
        year = 1900 + frame[7]
        month = 1 + frame[8]
        day = frame[9]
        height = frame[10]
        male = (frame[11] & 0xF0) != 0
        activity = frame[11] & 0x0F
        return RemoteUser(
            uid=uid,
            name=name,
            year=year,
            birthday=f"{year:04d}-{month:02d}-{day:02d}",
            height_cm=height,
            sex="male" if male else "female",
            activity=activity,
        )

    async def get_saved_measurements(
        self,
        uid: int,
        *,
        delete_after: bool = False,
    ) -> list[Measurement]:
        measurements: list[Measurement] = []
        await self._write(self._cmd(CMD_GET_SAVED_MEASUREMENTS, *encode_user_id(uid)))

        ack = await self._wait(
            lambda f: len(f) >= 4
            and f[0] == START_CMD
            and f[1] == CMD_SCALE_ACK
            and f[2] == CMD_GET_SAVED_MEASUREMENTS
        )
        parts = ack[3]
        self._log(f"saved measurement parts: {parts}")
        if parts == 0:
            return measurements

        # Each measurement arrives as 2 parts (odd=first, even=second).
        first: Optional[bytes] = None
        received = 0
        while received < parts:
            frame = await self._wait(
                lambda f: len(f) >= 5
                and f[0] == START_CMD
                and f[1] == CMD_SAVED_MEASUREMENT,
            )
            await self._ack(frame)
            received = frame[3]
            total = frame[2]
            payload = frame[4:]
            is_first = (received % 2) == 1
            if is_first:
                first = payload
            else:
                if first is None:
                    self._log("got second part without first; skipping")
                    continue
                merged = first + payload
                first = None
                try:
                    measurements.append(Measurement.from_payload(merged, uid=uid))
                except ValueError as exc:
                    self._log(f"parse error: {exc}")
            if received == total:
                break

        if delete_after and measurements:
            await self.delete_saved_measurements(uid)

        return measurements

    async def live_measure(
        self,
        uid: int,
        *,
        hold_s: float = 20.0,
    ) -> tuple[list[float], Optional[Measurement]]:
        """Trigger measurement for uid; collect live weights + body-comp if available."""
        weights: list[float] = []
        await self._write(self._cmd(CMD_DO_MEASUREMENT, *encode_user_id(uid)))
        ack = await self._wait(
            lambda f: len(f) >= 4
            and f[0] == START_CMD
            and f[1] == CMD_SCALE_ACK
            and f[2] == CMD_DO_MEASUREMENT
        )
        if ack[3] != 0:
            raise RuntimeError(
                f"DO_MEASUREMENT rejected (status={ack[3]}). "
                "Is the user registered on the scale?"
            )

        print("Step on the scale…", file=sys.stderr)
        deadline = time.monotonic() + hold_s
        parts: dict[int, bytes] = {}
        total_parts: Optional[int] = None
        measurement_uid: Optional[int] = None

        while time.monotonic() < deadline:
            try:
                frame = await asyncio.wait_for(
                    self._queue.get(),
                    timeout=max(0.1, deadline - time.monotonic()),
                )
            except asyncio.TimeoutError:
                break

            if len(frame) < 2 or frame[0] != START_CMD:
                continue

            cmd = frame[1]
            if cmd == CMD_WEIGHT_MEASUREMENT and len(frame) >= 5:
                await self._ack(frame)
                # SBF70 compact: [E7 58 flag wh wl]
                w = kg_from_raw(frame, 3)
                stable = frame[2] == 0
                weights.append(round(w, 2))
                print(
                    f"  weight={'%.2f' % w} kg ({'stable' if stable else 'live'})",
                    file=sys.stderr,
                )
            elif cmd == CMD_MEASUREMENT and len(frame) >= 4:
                await self._ack(frame)
                current = frame[3]
                total_parts = frame[2]
                if current == 1 and len(frame) >= 13:
                    measurement_uid = decode_user_id(frame, 5)
                else:
                    parts[current] = frame[4:]
                if total_parts is not None and current == total_parts and len(parts) >= 1:
                    # Join parts 2..N (part 1 is UID metadata).
                    ordered = [parts[i] for i in sorted(parts) if i >= 2]
                    if ordered:
                        merged = b"".join(ordered)
                        try:
                            return weights, Measurement.from_payload(
                                merged, uid=measurement_uid or uid
                            )
                        except ValueError as exc:
                            self._log(f"live compose parse error: {exc}")
                            return weights, None

        return weights, None

    async def _wait_scale_ack(self, for_cmd: int) -> bytes:
        frame = await self._wait(
            lambda f: len(f) >= 4
            and f[0] == START_CMD
            and f[1] == CMD_SCALE_ACK
            and f[2] == for_cmd
        )
        return frame

    async def delete_saved_measurements(self, uid: int) -> bool:
        """CMD 0x43 — clear all saved history for one user."""
        await self._write(self._cmd(CMD_DELETE_SAVED_MEASUREMENTS, *encode_user_id(uid)))
        ack = await self._wait_scale_ack(CMD_DELETE_SAVED_MEASUREMENTS)
        ok = ack[3] == 0
        self._log(
            f"delete saved for uid={uid_hex(uid)} → {'ok' if ok else 'status=' + str(ack[3])}"
        )
        return ok

    async def list_unknown_measurements(self) -> list[UnknownMeasurement]:
        """CMD 0x46 / 0x47 — guest measurements with stable slot indices."""
        unknowns: list[UnknownMeasurement] = []
        await self._write(self._cmd(CMD_GET_UNKNOWN_MEASUREMENTS))
        ack = await self._wait_scale_ack(CMD_GET_UNKNOWN_MEASUREMENTS)
        # bt-scale: e7 f0 46 00 → has items; e7 f0 46 01 → none
        if len(ack) >= 4 and ack[3] != 0:
            self._log("no unknown measurements")
            return unknowns

        while True:
            frame = await self._wait(
                lambda f: len(f) >= 12
                and f[0] == START_CMD
                and f[1] == CMD_UNKNOWN_MEASUREMENT_INFO
            )
            await self._ack(frame)
            total = frame[2]
            current = frame[3]
            # Layout after start+cmd+total+current: slot(1) ts(4) weight(2) Z(2)
            slot = frame[4]
            ts = _u32_be(frame, 5)
            weight = kg_from_raw(frame, 9)
            impedance = _u16_be(frame, 11) if len(frame) >= 13 else 0
            unknowns.append(
                UnknownMeasurement(
                    slot=slot,
                    timestamp=ts,
                    time_iso=datetime.fromtimestamp(ts, tz=timezone.utc).isoformat(),
                    weight_kg=round(weight, 2),
                    impedance=impedance,
                )
            )
            self._log(
                f"unknown {current}/{total} slot={slot} weight={weight:.2f} kg"
            )
            if current == total:
                break
        return unknowns

    async def delete_unknown_measurement(self, slot: int) -> bool:
        """CMD 0x49 — delete one unknown measurement by slot index."""
        if not 0 <= slot <= 255:
            raise ValueError(f"slot out of range: {slot}")
        await self._write(self._cmd(CMD_DELETE_UNKNOWN_MEASUREMENT, slot & 0xFF))
        ack = await self._wait_scale_ack(CMD_DELETE_UNKNOWN_MEASUREMENT)
        ok = ack[3] == 0
        self._log(f"delete unknown slot={slot} → {'ok' if ok else 'status=' + str(ack[3])}")
        return ok

    async def delete_user(self, uid: int) -> bool:
        """CMD 0x32 — remove a user profile from the scale."""
        await self._write(self._cmd(CMD_USER_DELETE, *encode_user_id(uid)))
        ack = await self._wait_scale_ack(CMD_USER_DELETE)
        ok = ack[3] == 0
        self._log(f"delete user uid={uid_hex(uid)} → {'ok' if ok else 'status=' + str(ack[3])}")
        return ok


def confirm_or_exit(args: argparse.Namespace, message: str) -> None:
    if getattr(args, "yes", False):
        return
    print(message, file=sys.stderr)
    answer = input("Type YES to continue: ").strip()
    if answer != "YES":
        raise SystemExit("aborted")


async def discover(
    timeout: float = 12.0,
    address: Optional[str] = None,
) -> list[tuple[BLEDevice, AdvertisementData]]:
    found: dict[str, tuple[BLEDevice, AdvertisementData]] = {}

    def _cb(device: BLEDevice, adv: AdvertisementData) -> None:
        name = device.name or adv.local_name
        if address:
            if device.address.lower() == address.lower():
                found[device.address] = (device, adv)
            return
        if name_matches(name):
            found[device.address] = (device, adv)

    async with BleakScanner(detection_callback=_cb):
        await asyncio.sleep(timeout)

    return list(found.values())


async def resolve_address(args: argparse.Namespace) -> str:
    if args.address:
        return args.address
    hits = await discover(timeout=args.scan_timeout)
    if not hits:
        raise SystemExit(
            "No SBF70-family scale found. Wake it (step on briefly) and retry, "
            "or pass --address <MAC/UUID>."
        )
    if len(hits) > 1 and not args.address:
        print("Multiple devices:", file=sys.stderr)
        for dev, adv in hits:
            print(f"  {dev.address}  {dev.name or adv.local_name}", file=sys.stderr)
        raise SystemExit("Pass --address to pick one.")
    return hits[0][0].address


def print_json(obj: Any) -> None:
    def _default(o: Any) -> Any:
        if hasattr(o, "__dataclass_fields__"):
            return asdict(o)
        raise TypeError(type(o))

    print(json.dumps(obj, indent=2, default=_default))


async def cmd_scan(args: argparse.Namespace) -> None:
    hits = await discover(timeout=args.scan_timeout, address=args.address)
    if not hits:
        print("[]")
        print("No matching devices. Wake the scale and try again.", file=sys.stderr)
        return
    out = [
        {
            "address": dev.address,
            "name": dev.name or adv.local_name,
            "rssi": adv.rssi,
        }
        for dev, adv in hits
    ]
    print_json(out)


async def cmd_status(args: argparse.Namespace) -> None:
    address = await resolve_address(args)
    async with Sbf70Client(address, verbose=args.verbose, timeout=args.timeout) as client:
        await client.init_session()
        status = await client.get_status()
        result = SessionResult(address=address, name=client._name, status=status)
        print_json(result)


async def cmd_users(args: argparse.Namespace) -> None:
    address = await resolve_address(args)
    async with Sbf70Client(address, verbose=args.verbose, timeout=args.timeout) as client:
        await client.init_session()
        status = await client.get_status()
        users = await client.list_users()
        if args.details:
            detailed: list[RemoteUser] = []
            for u in users:
                try:
                    detailed.append(await client.user_details(u.uid))
                except Exception as exc:
                    u_err = RemoteUser(uid=u.uid, name=u.name, year=u.year)
                    detailed.append(u_err)
                    print(f"details failed for {uid_hex(u.uid)}: {exc}", file=sys.stderr)
            users = detailed
        # Serialize with hex uid for readability
        payload = {
            "address": address,
            "name": client._name,
            "status": asdict(status) if status else None,
            "users": [
                {
                    **asdict(u),
                    "uid": uid_hex(u.uid),
                }
                for u in users
            ],
        }
        print_json(payload)


async def cmd_history(args: argparse.Namespace) -> None:
    address = await resolve_address(args)
    async with Sbf70Client(address, verbose=args.verbose, timeout=args.timeout) as client:
        await client.init_session()
        status = await client.get_status()
        users = await client.list_users()

        targets = users
        if args.uid:
            want = parse_uid(args.uid)
            targets = [u for u in users if u.uid == want]
            if not targets:
                # Still try the requested UID (scale may accept it).
                targets = [RemoteUser(uid=want, name="?", year=0)]

        all_meas: list[dict[str, Any]] = []
        for u in targets:
            meas = await client.get_saved_measurements(
                u.uid, delete_after=args.delete
            )
            for m in meas:
                d = asdict(m)
                d["uid"] = uid_hex(m.uid) if m.uid is not None else None
                d["user_name"] = u.name
                all_meas.append(d)

        print_json(
            {
                "address": address,
                "name": client._name,
                "status": asdict(status),
                "users": [{"uid": uid_hex(u.uid), "name": u.name, "year": u.year} for u in users],
                "measurements": all_meas,
            }
        )


async def cmd_measure(args: argparse.Namespace) -> None:
    if not args.uid:
        raise SystemExit("--uid is required for live measure (hex, e.g. 0000000000000065)")
    address = await resolve_address(args)
    uid = parse_uid(args.uid)
    async with Sbf70Client(address, verbose=args.verbose, timeout=args.timeout) as client:
        await client.init_session()
        status = await client.get_status(uid)
        weights, measurement = await client.live_measure(uid, hold_s=args.hold)
        out: dict[str, Any] = {
            "address": address,
            "name": client._name,
            "status": asdict(status),
            "live_weights": weights,
            "measurement": None,
        }
        if measurement:
            d = asdict(measurement)
            d["uid"] = uid_hex(measurement.uid) if measurement.uid is not None else None
            out["measurement"] = d
        print_json(out)


async def cmd_unknown(args: argparse.Namespace) -> None:
    address = await resolve_address(args)
    async with Sbf70Client(address, verbose=args.verbose, timeout=args.timeout) as client:
        await client.init_session()
        await client.get_status()
        unknowns = await client.list_unknown_measurements()
        print_json(
            {
                "address": address,
                "name": client._name,
                "unknown_measurements": [asdict(u) for u in unknowns],
            }
        )


async def cmd_delete_saved(args: argparse.Namespace) -> None:
    uid = parse_uid(args.uid)
    confirm_or_exit(
        args,
        f"This will delete ALL saved measurements for user {uid_hex(uid)} on the scale.",
    )
    address = await resolve_address(args)
    async with Sbf70Client(address, verbose=args.verbose, timeout=args.timeout) as client:
        await client.init_session()
        await client.get_status()
        ok = await client.delete_saved_measurements(uid)
        print_json(
            {
                "address": address,
                "name": client._name,
                "operation": "delete-saved",
                "uid": uid_hex(uid),
                "ok": ok,
            }
        )
        if not ok:
            raise SystemExit(1)


async def cmd_delete_unknown(args: argparse.Namespace) -> None:
    if args.all and args.index is not None:
        raise SystemExit("Use either --index or --all, not both.")
    if not args.all and args.index is None:
        raise SystemExit("Pass --index N or --all (see also: unknown).")

    address = await resolve_address(args)
    async with Sbf70Client(address, verbose=args.verbose, timeout=args.timeout) as client:
        await client.init_session()
        await client.get_status()

        if args.all:
            unknowns = await client.list_unknown_measurements()
            slots = [u.slot for u in unknowns]
            if not slots:
                print_json(
                    {
                        "address": address,
                        "name": client._name,
                        "operation": "delete-unknown",
                        "deleted": [],
                        "ok": True,
                    }
                )
                return
            confirm_or_exit(
                args,
                f"This will delete {len(slots)} unknown measurement(s) "
                f"(slots {slots}) on the scale.",
            )
        else:
            slots = [int(args.index)]
            confirm_or_exit(
                args,
                f"This will delete unknown measurement slot {slots[0]} on the scale.",
            )

        results: list[dict[str, Any]] = []
        all_ok = True
        for slot in slots:
            ok = await client.delete_unknown_measurement(slot)
            results.append({"slot": slot, "ok": ok})
            all_ok = all_ok and ok

        print_json(
            {
                "address": address,
                "name": client._name,
                "operation": "delete-unknown",
                "deleted": results,
                "ok": all_ok,
            }
        )
        if not all_ok:
            raise SystemExit(1)


async def cmd_delete_user(args: argparse.Namespace) -> None:
    uid = parse_uid(args.uid)
    confirm_or_exit(
        args,
        f"This will DELETE user profile {uid_hex(uid)} from the scale "
        "(and typically its associated data).",
    )
    address = await resolve_address(args)
    async with Sbf70Client(address, verbose=args.verbose, timeout=args.timeout) as client:
        await client.init_session()
        await client.get_status()
        ok = await client.delete_user(uid)
        print_json(
            {
                "address": address,
                "name": client._name,
                "operation": "delete-user",
                "uid": uid_hex(uid),
                "ok": ok,
            }
        )
        if not ok:
            raise SystemExit(1)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Sanitas SBF70 / Beurer BF710 BLE CLI (openScale protocol)"
    )
    p.add_argument(
        "-a",
        "--address",
        help="Scale MAC (Linux) or UUID (macOS). Auto-discovered if omitted.",
    )
    p.add_argument("-v", "--verbose", action="store_true", help="Log raw BLE frames")
    p.add_argument("--timeout", type=float, default=30.0, help="Per-response timeout (s)")
    p.add_argument(
        "--scan-timeout",
        type=float,
        default=12.0,
        help="Discovery duration (s)",
    )

    sub = p.add_subparsers(dest="command", required=True)

    sp = sub.add_parser("scan", help="Scan for SBF70-family scales")
    sp.set_defaults(func=cmd_scan)

    sp = sub.add_parser("status", help="Connect, init, read scale status / battery")
    sp.set_defaults(func=cmd_status)

    sp = sub.add_parser("users", help="List users stored on the scale")
    sp.add_argument(
        "--details",
        action="store_true",
        help="Also fetch birthday/height/sex/activity per user",
    )
    sp.set_defaults(func=cmd_users)

    sp = sub.add_parser("history", help="Download saved measurements")
    sp.add_argument("--uid", help="Only this user id (hex). Default: all known users.")
    sp.add_argument(
        "--delete",
        action="store_true",
        help="Delete saved measurements on scale after download",
    )
    sp.set_defaults(func=cmd_history)

    sp = sub.add_parser("measure", help="Trigger a live measurement for a user")
    sp.add_argument("--uid", required=True, help="User id on the scale (hex)")
    sp.add_argument(
        "--hold",
        type=float,
        default=20.0,
        help="Seconds to wait for body-comp after weigh-in",
    )
    sp.set_defaults(func=cmd_measure)

    sp = sub.add_parser(
        "unknown",
        help="List unknown (guest) measurements and their slot indices",
    )
    sp.set_defaults(func=cmd_unknown)

    sp = sub.add_parser(
        "delete-saved",
        help="Delete all saved measurements for a user (CMD 0x43)",
    )
    sp.add_argument("--uid", required=True, help="User id on the scale (hex)")
    sp.add_argument(
        "-y",
        "--yes",
        action="store_true",
        help="Skip confirmation prompt",
    )
    sp.set_defaults(func=cmd_delete_saved)

    sp = sub.add_parser(
        "delete-unknown",
        help="Delete unknown measurement(s) by slot (CMD 0x49)",
    )
    sp.add_argument(
        "--index",
        type=int,
        help="Slot index from 'unknown' listing",
    )
    sp.add_argument(
        "--all",
        action="store_true",
        help="Delete every unknown measurement currently stored",
    )
    sp.add_argument(
        "-y",
        "--yes",
        action="store_true",
        help="Skip confirmation prompt",
    )
    sp.set_defaults(func=cmd_delete_unknown)

    sp = sub.add_parser(
        "delete-user",
        help="Delete a user profile from the scale (CMD 0x32)",
    )
    sp.add_argument("--uid", required=True, help="User id on the scale (hex)")
    sp.add_argument(
        "-y",
        "--yes",
        action="store_true",
        help="Skip confirmation prompt",
    )
    sp.set_defaults(func=cmd_delete_user)

    return p


def main(argv: Optional[list[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        asyncio.run(args.func(args))
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        return 130
    except TimeoutError as exc:
        print(f"timeout: {exc}", file=sys.stderr)
        print("Wake the scale (step on it) and retry.", file=sys.stderr)
        return 1
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        if getattr(args, "verbose", False):
            raise
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
