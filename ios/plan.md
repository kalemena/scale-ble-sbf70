# Plan: Native SwiftUI iPhone app for the SBF70 BLE scale

Status: implemented (v1) — awaiting on-device verification (requires Xcode + physical iPhone)
Target: `ios/` directory of this repository
Owner: iOS app (Swift/SwiftUI), ported from `tools/sbf70-cli/sbf70.py`

---

## 1. Goal

Build a native iPhone application that talks directly to the Sanitas SBF70 /
Beurer BF710 / Silvercrest SBF75 / Crane AICDSCALE1 family of body scales over
BLE, porting the working Python CLI (`tools/sbf70-cli/sbf70.py`) to
Swift/CoreBluetooth.

Version 1 features (agreed scope):

- Sync saved history from the scale (port of `sbf70.py history`)
- History list with charts (Swift Charts; ideas from `tools/measurements-report.py`)
- Live measurement mode (port of `sbf70.py measure`)
- User management on the scale (list/add/update/delete; port of `users`)

Explicitly out of scope for v1: HealthKit export, guest/unknown measurement
claiming (`0x46`/`0x47`/`0x4B`), cloud sync.

## 2. Decisions

| Topic | Decision |
|---|---|
| Tech stack | Native SwiftUI, Swift concurrency (async/await) |
| Min iOS | iOS 17 |
| BLE | CoreBluetooth, no third-party BLE library |
| Storage | Plain JSON files in `Documents/Sbf70/` (no Core Data / SwiftData) |
| Location | `ios/` inside this repo, alongside `tools/` |
| Project generation | Xcode GUI (xcodegen not installed; optional later) |
| Testability | Protocol layer behind a `ScaleTransport` protocol, mockable in unit tests |

## 3. Protocol reference (from the Python CLI)

Everything below is implemented in `tools/sbf70-cli/sbf70.py`; the Swift port
must keep identical names/opcodes for easy cross-reference.

### 3.1 GATT

| Item | Value | Source |
|---|---|---|
| Service | `0000ffe0-0000-1000-8000-00805f9b34fb` (0xFFE0) | `sbf70.py:40` |
| Characteristic (notify + write) | `0000ffe1-0000-1000-8000-00805f9b34fb` (0xFFE1) | `sbf70.py:41` |

- No pairing, no bonding, no encryption. Plain GATT **write-with-response**
  (`write_gatt_char(..., response=True)`, `sbf70.py:277`) plus notifications.
- The only handshake is the application-level INIT/SET_TIME sequence.

### 3.2 Frame start bytes (`sbf70.py:44-47`)

| Byte | Constant | Meaning |
|---|---|---|
| `0xE7` | `START_CMD` | Normal command/response frame |
| `0xE6` | `START_INIT` | Session INIT |
| `0xE9` | `START_TIME` | SET_TIME |
| `0xEA` | `START_DISCONNECT` | Graceful disconnect |

(BF700/BF800 variants use `0xF7` instead of `0xE7` — documented, not
implemented.)

### 3.3 Command opcodes (`sbf70.py:49-69`)

| Code | Name | Code | Name |
|---|---|---|---|
| `0x31` | USER_ADD | `0x47` | UNKNOWN_MEASUREMENT_INFO |
| `0x32` | USER_DELETE | `0x49` | DELETE_UNKNOWN_MEASUREMENT |
| `0x33` | USER_LIST | `0x4B` | ASSIGN_UNKNOWN_MEASUREMENT |
| `0x34` | USER_INFO (per-user record) | `0x4C` | UNKNOWN_MEASUREMENT |
| `0x35` | USER_UPDATE | `0x4D` | SET_UNIT |
| `0x36` | USER_DETAILS | `0x4F` | SCALE_STATUS |
| `0x40` | DO_MEASUREMENT | `0x58` | WEIGHT_MEASUREMENT (live) |
| `0x41` | GET_SAVED_MEASUREMENTS | `0x59` | MEASUREMENT (body-comp parts) |
| `0x42` | SAVED_MEASUREMENT (data) | `0xF0` | SCALE_ACK (scale -> app) |
| `0x43` | DELETE_SAVED_MEASUREMENTS | `0xF1` | APP_ACK (app -> scale) |
| `0x46` | GET_UNKNOWN_MEASUREMENTS | | |

### 3.4 ACK protocol

- Scale -> app ACK (`0xF0`): responses look like `E7 F0 <echo of cmd>
  <status/payload...>` (`_wait_scale_ack`, `sbf70.py:536-543`).
- App -> scale ACK (`0xF1`): for streaming frames the app must echo bytes
  `[1..3]` of the received frame: `E7 F1 <b1> <b2> <b3>` (`_ack`,
  `sbf70.py:282-286`).
- Auto-ACK is required for commands `0x34, 0x42, 0x58, 0x59, 0x47, 0x4C`
  (`sbf70.py:301-309`). Without it the scale stops sending multi-part data.

### 3.5 Connection flow

1. **Wake the scale** — it sleeps aggressively; step on it, connect within
   ~15 s (`README.adoc:12-15`, `sbf70.py:9`).
2. **Scan** — `discover()` (`sbf70.py:623-641`): filter by name substring
   against `NAME_HINTS` (`sbf70.py:71-84`): "sanitas sbf70", "sbf75",
   "aicdscale1", "beurer bf710", "bf700", "bf-700", "bf-800", "rt-libra",
   "libra-b", "libra-w"; or exact address.
3. **Connect** — `BleakClient.connect()` then `start_notify(CHAR_UUID, ...)`
   (`sbf70.py:242-247`).
4. **Session init** (`sbf70.py:313-324`):
   - Drain stale notifications.
   - Write `E6 01`, wait for any reply starting with `0xE6`.
   - Write `E9` + big-endian uint32 Unix time; **no ACK expected**, just
     sleep ~0.15 s.
5. **Query** — status/users/history/measure (see below).
6. **Disconnect** — write `EA 02`, stop notify, disconnect (`sbf70.py:249-260`).

### 3.6 Command request patterns

Every command frame is `[0xE7, CMD, params...]` via `_cmd()`
(`sbf70.py:279-280`). User IDs are 8 bytes big-endian (`encode_user_id`,
`sbf70.py:117-118`), hex-formatted as 16 digits.

- **Status** `get_status()` (`sbf70.py:326-345`): `E7 4F <uid8>` ->
  `E7 F0 4F ...` (>=12 bytes). Layout: `[4]` battery, `[5]` weight threshold
  (÷10 kg), `[6]` fat threshold (÷10), `[7]` unit (1=kg, 2=lb, 4=st),
  `[8..10]` user exists / ref-weight / measurement flags (0 = exists),
  `[11]` version.
- **User list** `list_users()` (`sbf70.py:347-380`): `E7 33` -> ACK
  `E7 F0 33 ... count max`; then N x `E7 34 <total> <current> <uid8> <name3>
  <year_off>` frames, each auto-ACKed. Name = 3 ASCII chars at offset 12,
  year = `1900 + frame[15]`.
- **User details** `user_details()` (`sbf70.py:382-407`): `E7 36 <uid8>` ->
  `E7 F0 36 status name3 year month day height sex/activity`;
  `frame[11] & 0xF0` = male, `& 0x0F` = activity level.
- **Saved history** `get_saved_measurements()` (`sbf70.py:409-461`):
  `E7 41 <uid8>` -> ACK carries `parts = ack[3]`; then parts arrive as
  `E7 42 <total> <received> <payload...>` — **odd part = first half, even
  part = second half** — each ACKed; halves concatenated and parsed by
  `Measurement.from_payload`. Optional `delete_after` -> `E7 43`.
- **Live measurement** `live_measure()` (`sbf70.py:463-534`):
  - `E7 40 <uid8>` -> `E7 F0 40 <status>`; non-zero = user not registered.
  - Listen (default 20-30 s hold):
    - `E7 58 <flag> <wh> <wl>` compact weight frames; flag 0 = stable,
      else live; weight = BE uint16 x 50 g; each ACKed.
    - `E7 59 <total> <current> ...` body-comp parts; part 1 carries the
      measurement uid at offset 5; parts 2..N carry payload bytes; when
      `current == total`, parts 2..N are concatenated and parsed as
      `Measurement`. Impedance often arrives several seconds after weight
      stabilizes (`README.adoc:208`).
- **Deletes**: `0x43` saved (`sbf70.py:545-553`), `0x49 <slot>` unknown
  (`sbf70.py:595-603`), `0x32 <uid8>` user (`sbf70.py:605-611`) — all wait
  for `E7 F0 <cmd> status`, success = `status == 0`.

### 3.7 Measurement payload (`Measurement.from_payload`, `sbf70.py:187-202`)

16 bytes, all big-endian:

| Offset | Size | Field | Scaling |
|---|---|---|---|
| 0 | 4 | Unix timestamp (s, UTC) | u32 |
| 4 | 2 | Weight | x 50 g (`kg_from_raw`, `sbf70.py:101-103`) |
| 6 | 2 | Impedance (ohm) | raw u16 |
| 8 | 2 | Fat % | ÷ 10 (`percent_from_raw`, `sbf70.py:106-108`) |
| 10 | 2 | Water % | ÷ 10 |
| 12 | 2 | Muscle % | ÷ 10 |
| 14 | 2 | Bone mass | x 50 g |

Buffers shorter than 16 bytes raise an error (`sbf70.py:189-190`).

### 3.8 Known gotchas (from `tools/sbf70-cli/README.adoc`)

- Scale sleeps; wake by stepping on it, then scan immediately (~15 s window).
- Another phone app (HealthCoach, openScale) may hold the connection.
- Body composition is zero/missing if the user is not registered on the scale.
- User nicknames are 3 characters; uid must be a real uid from `users`.
- No "wipe all history" opcode; space is freed via `delete-saved` +
  `delete-unknown --all` (`README.adoc:270-279`).

## 4. Architecture

Final layout (as implemented):

```
ios/
├── plan.md                     # this file
├── .gitignore                  # Xcode (xcuserdata/, DerivedData/, .xcodeproj/)
├── project.yml                 # XcodeGen spec — regenerate with `xcodegen generate`
├── Sbf70App.xcodeproj/         # generated, not committed
├── Sbf70Kit/                   # local Swift package (protocol + storage; no SwiftUI)
│   ├── Package.swift           # iOS 17 / macOS 14
│   ├── Sources/Sbf70Kit/
│   │   ├── ScaleProtocol.swift # UUIDs, opcodes, start bytes, frame codec, BE helpers
│   │   ├── ScaleTransport.swift# protocol: notifications AsyncStream + write + close
│   │   ├── CoreBluetoothTransport.swift  # CBCentralManager impl + ScaleScanner
│   │   ├── SBF70Client.swift   # actor: queue + predicate wait + auto-ACK (port of Sbf70Client)
│   │   ├── Models.swift        # ScaleStatus / ScaleUser / ScaleMeasurement (Codable, CLI keys)
│   │   └── JsonStore.swift     # actor over Documents/Sbf70/*.json
│   ├── Sources/sbf70-smoke/    # `swift run sbf70-smoke` — protocol checks w/o Xcode
│   └── Tests/Sbf70KitTests/    # XCTest suite (runs in Xcode / CI with Xcode)
│       ├── MockTransport.swift
│       ├── FrameCodecTests.swift
│       ├── SBF70ClientTests.swift
│       └── JsonStoreTests.swift
├── Sbf70App/                   # app target (thin SwiftUI shell)
│   ├── Sbf70App.swift          # @main entry
│   ├── Info.plist              # generated by XcodeGen (BLE usage string, launch screen)
│   ├── ViewModels/
│   │   ├── AppSettings.swift   # shared settings mirror (active uid, sync prefs)
│   │   ├── SessionViewModel.swift      # one connected SBF70Client for all screens
│   │   ├── SyncViewModel.swift
│   │   ├── UsersViewModel.swift
│   │   └── LiveMeasureViewModel.swift
│   └── Views/
│       ├── RootView.swift             # TabView: Measure / History / Users / Settings
│       ├── ScannerView.swift          # scan list + wake-the-scale instructions
│       ├── LiveMeasureView.swift      # live weight, stable flag, body-comp result
│       ├── SyncView.swift             # pull saved history, progress, delete-after toggle
│       ├── HistoryView.swift          # list + Swift Charts + JSON export
│       ├── UsersView.swift            # list/details/add(experimental)/delete users
│       └── SettingsView.swift         # active user, sync prefs, CLI import, wipe
```

### 4.1 Key design decisions

- **`ScaleTransport` protocol**: `Sbf70Client` never talks to CoreBluetooth
  directly. It consumes an `AsyncStream<Data>` of notifications and a
  `write(Data) async throws`. `CoreBluetoothTransport` is the only
  CoreBluetooth-aware type; tests use `MockTransport` with scripted frames.
- **Concurrency**: Swift concurrency throughout. An internal actor inside
  `Sbf70Client` owns the notification queue and implements the
  `_wait(predicate, timeout, autoAck)` pattern from `sbf70.py:288-311`.
- **Write-with-response** for every command, matching the Python
  `response=True` behavior.
- **One session at a time**: `SessionViewModel` owns a single connected
  `Sbf70Client`; Sync/Live/Users screens share it. Connect performs the
  INIT/SET_TIME handshake once.
- **JSON storage** (`JsonStore` actor):
  - `Documents/Sbf70/settings.json` — last peripheral UUID, active uid, unit,
    delete-after-sync flag.
  - `Documents/Sbf70/users.json` — cached user list.
  - `Documents/Sbf70/measurements-<uid>.json` — sorted by timestamp, deduped
    on write.
  - Schema mirrors the CLI JSON output (`timestamp`, `time_iso`, `weight_kg`,
    `impedance`, `fat_pct`, `water_pct`, `muscle_pct`, `bone_kg`, `uid`) so
    files remain interchangeable with `tools/measurements-report.py`.
  - Import helper: load a CLI `history` JSON export (e.g. `test-cle.json`)
    to seed the app without the scale (useful for UI development).

## 5. Step-by-step implementation

### Step 0 — Prerequisites

- [ ] Install **Xcode from the App Store** (machine currently has only
      Command Line Tools; `xcodebuild` unavailable).
- [ ] Install iOS 17+ SDK support; sign in with Apple ID for device deployment.
- [ ] Physical **iPhone** required for BLE testing (the simulator has no
      Bluetooth).
- [ ] Optional: `brew install xcodegen` if a reproducible `project.yml` is
      preferred later; v1 uses the Xcode GUI.

### Step 1 — Scaffold the project

- [x] `ios/.gitignore` for Xcode (`xcuserdata/`, `DerivedData/`, `Sbf70App.xcodeproj/`).
- [x] `project.yml` (XcodeGen) — app target + local `Sbf70Kit` package.
- [x] `xcodegen generate` produces `Sbf70App.xcodeproj` (requires `brew install xcodegen`).
- [x] `Info.plist` generated with `NSBluetoothAlwaysUsageDescription`, empty `UILaunchScreen`.
- [x] Basic `RootView` TabView with all four screens.

### Step 2 — Protocol layer (`Sbf70Kit`)

Port from `sbf70.py`, keeping constant/opcode names identical:

- [x] `ScaleProtocol.swift`:
  - service/characteristic UUIDs (`sbf70.py:40-41`)
  - start bytes `E7/E6/E9/EA` (`:44-47`)
  - opcodes (`:49-69`), `NAME_HINTS` (`:71-84`), unit names (`:86`)
  - `kg_from_raw` / `percent_from_raw` (`:101-108`)
  - uid encode/decode, big-endian helpers (`:111-122`)
  - `Measurement` 16-byte payload parse (`:187-202`)
- [x] `ScaleTransport.swift`: write + notification `AsyncStream`.
- [x] `SBF70Client.swift` (actor):
  - frame pump + polling `wait(for:timeout:autoAck:)` with auto `E7 F1 <echo[1..3]>` (`:282-311`)
  - `initSession` / `disconnect` (`:242-260`, `:313-324`)
  - `getStatus` (`:326-345`), `listUsers` / `userDetails` (`:347-407`)
  - `getSavedMeasurements` odd/even part-halving (`:409-461`)
  - `liveMeasure` — `0x40` -> `0x58` -> `0x59` (`:463-534`)
  - `deleteSavedMeasurements` / `deleteUser` (`:545-611`)
  - `addUser` — `E7 31` frame ported from openScale `createRemoteUser`
    (not in the Python CLI; experimental, unverified on hardware)
  - `nextRemoteUID` — openScale rule max(existing, 100) + 1
- [x] `CoreBluetoothTransport.swift` + `ScaleScanner` (name-hint filter).
- [x] Unit tests (`Sbf70KitTests`): codec round-trips, mock-transport
  init/status/users/history/live flows, ACK byte assertions, JsonStore
  merge/import. Run via Xcode (`swift test` needs Xcode's XCTest; without
  Xcode use `swift run sbf70-smoke`, which mirrors the same checks — 42/42
  passing on macOS with Command Line Tools only).

### Step 3 — Scanner + session

- [x] `ScaleScanner` (kit): start/stop scan, `NAME_HINTS` filter, found
      devices (name + RSSI + identifier), 12 s scan timeout,
      Bluetooth-unavailable state.
- [x] `ScannerView`: wake-the-scale instruction banner, found-device list,
      rescan toolbar button, auto-start scan on appear, connect progress.
- [x] `SessionViewModel`: owns one `SBF70Client`; on connect runs
      INIT/SET_TIME; state machine `.disconnected/.connecting/.ready/.failed`;
      persists last peripheral UUID + name; disconnects on backgrounding.

### Step 4 — Storage (`JsonStore`)

- [x] `JsonStore` actor: atomic writes; `settings.json`, `users.json`,
      `measurements-<uidHex>.json`.
- [x] Deduplicate measurements by timestamp on merge; keep sort order.
- [x] Settings persistence (last peripheral UUID, active uid,
      delete-after-sync) via shared `AppSettings`.
- [x] Import from CLI JSON export (`fileImporter` in Settings; accepts
      `sbf70.py history` output incl. `test-cle.json` shape).
- [x] Tests: merge/dedupe semantics, import round-trip, wipe.

### Step 5 — User management

- [x] `UsersViewModel`: pull user list (`0x33`/`0x34`) + details (`0x36`)
      from scale, cache to `users.json`; delete (`0x32`) with confirmation.
- [x] `UsersView`: list (nickname, year, height/sex/activity from details);
      tap to set active user; swipe to delete.
- [x] Add-user form (`E7 31`, openScale frame layout) — marked experimental
      in the UI; UPDATE (`0x35`) has no documented layout anywhere (openScale
      defines the constant but never sends it) so edit = delete + re-add.
- [x] UX notes: body composition requires a registered user on the scale.

### Step 6 — Sync saved history

- [x] `SyncViewModel`: run `getSavedMeasurements` for active uid with
      progress ("receiving part x/N"), merge into store, report counts
      (new / updated), **"delete from scale after sync"** toggle
      (default OFF, mirrored to settings; UI warns about limited scale
      memory and the absent full-wipe opcode — `README.adoc:270-279`).
- [x] `SyncView`: status check first (liveness/wake), Sync button with
      progress, result summary, error states.

### Step 7 — History & charts

- [x] `HistoryView`: Swift Charts — weight line + points; toggleable
      fat/water/muscle % overlays; row detail (impedance, bone via export).
- [x] List below the chart, newest first; swipe-delete per measurement.
- [x] Share sheet export of CLI-compatible JSON (feeds
      `tools/measurements-report.py`).
- [x] Auto-refresh on foreground / active-uid change.

### Step 8 — Live measurement

- [x] `LiveMeasureViewModel`: `E7 40 <uid8>`; rejection surfaces a
      user-registration hint; live `0x58` weights with stable flag;
      `0x59` parts with 30 s hold; auto-save to store.
- [x] `LiveMeasureView`: large live weight readout, stable/settling state,
      "measuring body composition…" hint, result card, saved badge.

### Step 9 — Polish & verification

- [ ] Per-wait timeouts (~5 s; live measure hold 20-30 s); user-facing error
      messages derived from the troubleshooting table
      (`README.adoc:386-407`).
- [ ] App icon, launch screen, navigation polish, haptics on measurement.
- [ ] Update root `README.adoc` with an iOS section (build, permissions,
      wake-up workflow, relationship to the CLI tools).
- [ ] **Parity check on device**: run `sbf70.py history` and the app against
      the same scale state; compare measurement counts/values; repeat for
      `users` and one live measurement.
- [ ] Unit tests green in simulator; manual test checklist executed on a
      physical iPhone (scan/wake, sync, sync+delete, users CRUD, live
      measure, Bluetooth-off recovery, app backgrounding mid-session).

## 6. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Scale sleeps (~15 s wake window) | Scanner banner instructs wake-then-scan; auto-retry once on timeout after connect failure |
| CoreBluetooth peripheral UUID instability on iOS | Persist last UUID; "forget device / rescan" path in Settings |
| Multi-part stream stalls if ACKs are late | Auto-ACK inside the frame pump (before predicate evaluation), mirroring `sbf70.py:301-309` |
| Body composition missing for unregistered user | Detect `0x40` non-zero status; guide user to create profile on the scale |
| Scale memory fills up (limited slots) | Sync-then-delete toggle; surface part counts; document that no full-wipe opcode exists |
| Simulator cannot test BLE | All logic behind `ScaleTransport`; mock-driven unit tests; device-only manual checklist |
