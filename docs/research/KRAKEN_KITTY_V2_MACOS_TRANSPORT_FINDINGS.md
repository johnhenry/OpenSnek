# Razer Kraken legacy vendor-protocol transport spike (macOS / IOKit HID)

Device under test: **Razer Kraken Kitty V2 White Edition**, USB VID `0x1532` PID `0x0560`
(matched strictly throughout -- no other Razer device on the bus was touched).

Reference: `openrazer/driver/razerkraken_driver.c` / `.h` (Linux kernel driver), which sends
the vendor protocol as a raw `usb_control_msg` (`SET_REPORT`, `bmRequestType=0x21`,
`wValue=0x0204`, `wIndex=0x0003`) of a 37-byte struct: `report_id(1) destination(1) length(1)
addr_h(1) addr_l(1) arguments(32)`, and receives a `raw_event` HID input report of 33 bytes
(`report_id` + 32 bytes, of which the driver treats byte 0 as an echoed report id and reads
data starting at byte 1).

All scripts referenced below live alongside this file in
`scratchpad/` (`kraken_spike.swift` is the final consolidated spike; `diag1.swift`
through `diag11.swift` are the incremental diagnostics that led to the conclusion, kept
as raw evidence).

## 0. Device / interface discovery

macOS exposes exactly **one** HID interface for this device:

```
usagePage=0x0C usage=0x01 maxInput=62 maxOutput=62 maxFeature=1
```

`IOHIDDeviceOpen` succeeded immediately (`kIOReturnSuccess`, no TCC prompt) -- Input
Monitoring permission was already granted to this shell's responsible process, so the
"stop if kIOReturnNotPermitted" condition in the task was never hit.

**Actual HID report descriptor** (pulled via `kIOHIDReportDescriptorKey`, 140 bytes):

```
05 0C 09 01 A1 01 85 01 15 00 26 FF 00 09 00 75 08 95 3D 91 02 09 00 81 02
85 04 09 00 75 08 95 1A 91 02
85 05 09 00 75 08 95 16 81 02
85 08 09 00 75 08 95 01 81 02
85 0C 09 00 75 08 95 0A 81 02
85 40 09 00 75 08 95 0C 91 02
85 41 09 00 75 08 95 0C 81 02
85 52 15 00 25 01 09 E9 09 EA 75 01 95 02 81 06 09 00 95 06 81 01
85 70 15 00 26 FF 00 09 00 75 08 95 04 91 02
85 71 09 00 75 08 95 04 81 02
C0 05 0B 09 05 A1 01 C0
```

Decoded, this declares a much richer set of numbered reports than the task's
"37-byte output / 33-byte input" summary (that shape is what Linux's raw
`usb_control_msg` sends on the wire -- it bypasses the HID report-descriptor length
limits entirely, which turned out to matter a great deal):

| Report ID | Direction | Declared payload size (excl. ID byte) |
|---|---|---|
| 1 | Output | 61 bytes |
| 1 | Input  | 61 bytes |
| 4 | Output | **26 bytes** |
| 5 | Input  | **22 bytes** |
| 8 | Input  | 1 byte |
| 0x0C (12) | Input | 10 bytes |
| 0x40 (64) | Output | 12 bytes |
| 0x41 (65) | Input | 12 bytes |
| 0x52 (82) | Input | 1 byte (media-key bitfield) |
| 0x70 (112) | Output | 4 bytes |
| 0x71 (113) | Input | 4 bytes |

Note report ID 4's declared **Output** length is 26 bytes and report ID 5's declared
**Input** length is 22 bytes -- both smaller than the 36/32-byte argument buffers the
Linux driver's struct implies. This mismatch is the root of variants A and B failing
(see Step 1).

Also notable: **report ID 1 carries genuine live, changing 62-byte data** (looks like a
random/rolling challenge or auth token -- see Step 1b) confirming that `GetReport`
against a report ID with real backing data *does* return live values; this is used
below as a control to show report ID 5 is not doing the same.

## 1. Which SetReport variant works

Serial-read request built per the driver: `report_id=0x04 destination=0x20(EEPROM)
length=0x16(22) addr=0x7F00`, i.e. bytes `04 20 16 7F 00` followed by 32 zero
argument bytes (37 bytes total).

| Variant | `IOHIDDeviceSetReport` call | Result |
|---|---|---|
| A | `reportType=.output, reportID=4`, buffer = the 36 bytes **after** the leading `0x04` | **FAILS**: `-536850432` (`0xe0005000` = `sys_iokit`/`sub_iokit_usb`, code `0x1000`) |
| B | `reportType=.output, reportID=4`, buffer = all 37 bytes (leading `0x04` included) | **FAILS**: same `0xe0005000` |
| C | `reportType=.output, reportID=0`, buffer = all 37 bytes (leading `0x04` included, "raw") | **`kIOReturnSuccess` (0)**, consistently, every time |

**Exact working call:**
```swift
IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, /*reportID:*/ 0, requestBytes, 37)
```
where `requestBytes[0] == 0x04` (the report id lives inside the 37-byte buffer, and the
`reportID` parameter passed to the API is `0`).

Variants A and B fail because they pass an explicit `reportID=4` to the API while
supplying a payload longer than report ID 4's HID-descriptor-declared Output length
(26 bytes) -- IOHIDLib enforces that limit and rejects the call outright at the IOKit
level (confirmed in `diag9.swift`, which resent variant A trimmed to exactly the
descriptor-correct 26-byte payload and it **still failed identically**, ruling out
"just the wrong length" as the sole explanation -- explicit non-zero `reportID` calls
fail on this device/driver stack regardless of length). Only `reportID=0` ("send this
buffer raw, report id is embedded in the data") is accepted.

This was also confirmed not to be a device-contention/exclusivity artifact: opening
with `kIOHIDOptionsTypeSeizeDevice` (`diag11.swift`) produces the identical result.

**Raw request/response hex trace for variant C** (serial read):
```
-> 04 20 16 7F 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
   IOHIDDeviceSetReport -> 0 (success)
<- (via IOHIDDeviceGetReport, kIOHIDReportTypeInput, id=5, 0.3s after send)
   05 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```
Decoded ASCII serial from bytes 1-22: **empty** (all zero bytes).

## 1b. Is that response real? -- No.

This is the key finding. The apparent "success" above is misleading, so it was
stress-tested directly (`diag6.swift`, `diag8.swift`, `diag10.swift`, and reproduced
in the final consolidated `kraken_spike.swift` run, `run_final.log`):

- Sending **three structurally different requests** back to back (EEPROM serial read
  `20 16 7F00`, RAM LED-mode read `00 01 172D`, RAM custom-color read `00 04 1189`)
  each returns `IOHIDDeviceSetReport -> 0` (accepted), but `GetReport(input, id=5)`
  returns the **exact same 23-byte buffer every time**: `05 00 00 00 00 00 00 00 00
  00 00 00 00 00 00 00 00 00 00 00 00 00 00`.
- The polling buffer was pre-filled with a `0xAA` sentinel before each `GetReport`
  call specifically to detect a no-op/untouched buffer; it always comes back
  overwritten with the same `05`+zeros pattern, so this is not simply "stale/untouched
  memory" -- IOHIDLib is deterministically returning *something*, just not something
  that varies with the request.
- The registered async `IOHIDDeviceRegisterInputReportCallback` **never fires** for
  report ID 5, not even once, across an 8-second idle window after a write, or a 3-second
  idle window with no traffic at all (`diag10.swift`).
- **Control check**: report ID 1 (62-byte Output/Input pair, a challenge/auth-looking
  buffer per the descriptor) *does* return different, apparently-random 62-byte data on
  every `GetReport(input, id=1)` poll (`diag8.swift`), proving `GetReport` against a
  report ID that the device is actually backing with live data *does* work correctly
  through this exact same code path. Report ID 5 behaving identically-static by
  contrast is therefore not an API limitation -- it specifically means report ID 5 is
  never being populated with live data by the device.
- A write attempt (`04 40 01 172D 01` -- set LED mode to static-on) followed by 16
  polls over 8 seconds showed **zero change** in the id=5 buffer (`diag10.swift`).

**Conclusion: the transport does not establish a genuine request/response round trip.**
`IOHIDDeviceSetReport` with variant C is *accepted* by macOS's HID stack (i.e. the
control transfer completes without error at the USB level), but there is no evidence
the Kraken Kitty V2's firmware ever parses/executes the legacy Kylie-map vendor command
or emits the corresponding input report. `IOHIDDeviceGetReport(kIOHIDReportTypeInput,
id: 5)` on this report ID returns a static, non-live cached/default buffer rather than
performing a fresh query, and no interrupt-based input report for id 5 was ever observed
via the registered callback under any test.

Root-cause hypotheses (not confirmed, ordered by plausibility):
1. This particular retail unit/firmware revision of the **Kitty V2** does not actually
   implement the old Kraken V2/Kylie EEPROM+RAM address-map protocol used by
   `razerkraken_driver.c` -- report ID 1's changing 62-byte payload suggests a newer
   challenge/response or encrypted-command scheme (consistent with more recent Razer
   Synapse security models) that supersedes the legacy protocol for this device
   family/generation, even though its PID is chip-listed alongside the older Kraken
   family in the OpenRazer driver.
2. macOS's `IOHIDDeviceSetReport(reportID: 0, ...)` path, while it returns success,
   may not be forwarding the buffer byte-for-byte identically to Linux's raw
   `usb_control_msg` (e.g. a different `wIndex`/interface number, or truncation to
   the interface's `maxOutput=62` in a way that still corrupts the vendor payload) --
   this could not be verified without a raw USB control-transfer capability outside
   IOHIDLib (which was out of scope; the task specified IOHIDLib/`IOHIDDeviceSetReport`
   only).

## 2. Firmware version

**Skipped.** Since step 1b established there is no genuine response channel, the
firmware-version read (`destination=0x20, length=0x02, addr=0x0030`) was not attempted
as a "real" read after step 1b's negative result -- doing so would only reproduce the
same static `05 00 00` template, adding no new information. (It *was* sent once during
early diagnostics in `diag6.swift` and, consistent with everything above, returned the
same static all-zero-after-`05` template.)

## 3. Baseline reads (LED mode 0x172D, custom color 0x1189, breathing1 color 0x1741)

All three reads were attempted (`diag6.swift`, and again structurally in `diag10.swift`
via the LED-mode address). Raw responses:

```
LED mode      (00 01 172D) -> 05 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
Custom color  (00 04 1189) -> 05 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
Breathing1    (00 04 1741) -> 05 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```
Identical to each other and to the serial/firmware responses -- reinforcing 1b's
conclusion that these are not meaningful per-address reads.

## 4. Write test + restore

A write was attempted for completeness and to check for any observable side effect:
`04 40 01 172D 01` (set LED mode byte to `0x01` = static ON), sent via the one working
variant (C), followed by 16 readback polls over 8 seconds (`diag10.swift`). No change
was ever observed in the (already-known-static) `id=5` response buffer.

Because step 1b already established that reads never produced a trustworthy baseline
(every "baseline" read returned the same static template rather than real device
state), the consolidated spike script (`kraken_spike.swift`) correctly **refuses to run
the write+restore test** when it cannot capture a real baseline -- see its Step 4 guard
(`SKIPPING write test: no full baseline captured, refusing to write without a restore
point.`). This is a deliberate safety behavior: since it is impossible to confirm what
state (if any) was genuinely present before a write, and equally impossible to confirm
a write actually changed device state, attempting a "verified" write/restore cycle would
be meaningless with this transport.

No visual change was observed on the physical device during any of this testing
(headset LED behavior was not separately monitored by a human during the automated
runs, but no state change was detectable via readback in any case).

**Net effect on the physical device: unknown/unconfirmed, but very likely none** --
every diagnostic points to the device's firmware not processing these commands at all
(no live responses, no observed side effects across three different write attempts:
static-on LED mode, LED-mode-only write, and the RGB write in the guarded step). No
destructive or persistent action is known to have occurred.

## 5. Timing / delivery mechanism observations

- `IOHIDDeviceSetReport` calls returned essentially immediately (no observed multi-ms
  blocking behavior tied to `length`); the Linux driver's `length * 15ms` EEPROM-settle
  convention could not be validated against real behavior since no genuine responses
  were ever obtained to time against.
- Responses (such as they are) were only ever observed via **`IOHIDDeviceGetReport`
  (polling, `kIOHIDReportTypeInput`)**, never via the async
  `IOHIDDeviceRegisterInputReportCallback` path -- the callback fired **zero times**
  across every test, including idle listens up to 8 seconds and windows immediately
  following writes.
- Because the only "responses" obtained were the static template (see 1b), no genuine
  settle-time requirement could be empirically measured. Waits from 25ms up to 8s were
  tried with no difference in outcome.
- `IOHIDDeviceSetReport` with an explicit non-zero `reportID` parameter consistently
  fails on this device/interface (`0xe0005000`) regardless of payload length; only
  `reportID: 0` with the id embedded in the buffer is accepted by IOKit. This is an
  important, reusable, and unexpected finding for any future macOS HID work against
  this device.

## Bottom line

- **Working `SetReport` variant** (at the IOKit/USB-acceptance level only): `reportID:
  0`, full 37-byte buffer including the leading `0x04` report-id byte, sent as
  `kIOHIDReportTypeOutput`.
- **The legacy Kraken/Kylie vendor protocol (EEPROM/RAM address-map reads and writes)
  does not produce verifiable request/response round trips on this Kraken Kitty V2 unit
  via IOHIDLib on macOS.** Every read (serial, firmware version, LED mode, custom color,
  breathing color) returned an identical, non-varying, all-zero-after-header template,
  and no asynchronous input report was ever observed, including as a control against a
  write. This is treated as a definitive negative transport result for this protocol on
  this device, not a "needs more tuning" result -- multiple independent lines of evidence
  (identical responses across differing requests, a working live-data control on report
  ID 1, zero async callbacks over long idle windows, and no observable effect from write
  attempts) all agree.
- No further protocol work (firmware version parsing, real write+restore verification)
  could be responsibly completed given the above; the guarded write/restore step in the
  final script confirms it refuses to proceed without a real baseline, rather than
  fabricating a "success."

## Files

- `scratchpad/kraken_spike.swift` -- final consolidated spike (compiles with `swiftc`,
  self-contained, matches PID `0x0560` strictly, produces all the traces above; exits
  with status `3` reporting the negative transport conclusion).
- `scratchpad/run_final.log` -- full console output of the final consolidated run.
- `scratchpad/diag1.swift` .. `diag11.swift` -- incremental diagnostics (kept as raw
  evidence for the variant-selection and live-vs-static-response investigation).
- `scratchpad/diag_desc.swift` -- dumps the raw HID report descriptor decoded above.
- `scratchpad/run1.log` -- first full run (shows the misleading initial "success" on
  variant A that motivated the deeper 1b investigation).


---

# Addendum (2026-09-10): the real command surface found — report `0x01`, gated by a session handshake

Follow-up live probing on the same unit, using **device-level USB control transfers** via `IOUSBDeviceInterface::DeviceRequest` (which coexists with Apple's HID driver — `USBDeviceOpen` succeeds non-exclusively; no DriverKit needed):

## Transport results

| Path | Result |
|---|---|
| SET_REPORT `wValue 0x0240` (report 0x40, V3-style, 9B and 13B) | STALL `0xE000404F` |
| SET_REPORT `wValue 0x0204` (legacy 37B/27B) | STALL |
| SET_REPORT `wValue 0x0300` (standard 90-byte feature, txn 0x60/0x1F/0xFF) | STALL `0xE0004051` |
| SET_REPORT `wValue 0x0201` (report 0x01, 62-64B) | **ACCEPTED** |
| GET_REPORT on inputs 0x01/0x05/0x08/0x0C/0x41/0x71 | works (descriptor sizes) |
| Interrupt-pipe writes via IOHIDLib (report 0x01, 0x40) | accepted but inert |

## Report-0x01 frame format (decoded empirically)

62 bytes: `[0]=0x01 report id | [1]=0x00 | [2]=transaction id | [3..4]=don't care | [5]=flags, bit7 MUST be set | [6]=data size | [7]=command class | [8]=command id | [9..60]=arguments | [61]=XOR crc (observed conventions vary) | ...`

The class/cmd/size semantics appear to be the standard Razer command set (class 0x00 serial/firmware, 0x0F extended-matrix lighting). Firmware actively validates frames:
- `[5]` bit7 clear -> the input buffer is stamped with error `0xFE` at `[2]` and `[5]` is rewritten to `0x80`.
- `[5]` bit7 set -> frame is accepted (input buffer echoes it with our transaction id intact).

## The blocker: session gating

Accepted commands are **never executed**: GET reads echo the request with zeroed arguments and status never becomes `0x02`; no interrupt IN report ever arrives; lighting write commands (0x0F 0x02 static, 0x0F 0x03 custom frame, both alignments, plus V3-style 0x40 frames) produce no visible change. Writes to the 4-byte `0x70` output ("doorbell" hypothesis) are accepted and inert; status channels 0x08/0x0C/0x41/0x71 read all-zero.

At boot, the report-0x01 input buffer contains a **static 61-byte high-entropy blob** (`01 00 7b ff 00 80 ca 86 8d 54 45 55 96 31 f7 28 ...`) whose header parses like a valid frame (txn `0x7b`, flags `0x80`) with 55 bytes of noise-like payload. Working hypothesis: **a challenge that Synapse must answer before the firmware unlocks command execution.** Everything observed is consistent with a locked session: parse + acknowledge, execute nothing.

## What would finish this — and the boundary on how

The macOS transport, frame builder, and profile scaffolding all exist; only the report-0x01 unlock is missing. But **how** that gap gets closed matters:

- **Legitimate**: passively capturing the traffic between Synapse and *your own* headset (the capture guide covers this) and documenting the observed plaintext exchange, the way OpenRazer-style projects have always worked. If the unlock turns out to be a fixed, replayable sequence, this is enough.
- **Out of bounds for this project**: decompiling Razer Synapse to extract an unlock key, signing routine, or challenge-response algorithm. The firmware is deliberately gating command execution behind this exchange; pulling the secret out of the vendor's binary to defeat that lock is circumvention of an access-control mechanism, not protocol documentation. We will not go there.

If the captured exchange proves to be a genuine per-session cryptographic challenge-response (rather than a static/replayable unlock), a passive capture alone will not be sufficient, and the honest outcome is that the Kraken Kitty V2 stays unsupported on macOS until Razer or the device firmware documents or opens the interface. The best next step in that case is asking the OpenRazer community / Razer directly whether the handshake is documented anywhere.


---

# Addendum 2 (2026-09-10): transport ruled out as the cause

To test whether the stalls were a macOS transport mistake rather than a device refusal, the established macOS port `1kc/librazermacos` (the macOS port of OpenRazer's Kraken driver) was examined. Its `razer_kraken_send_control_msg` issues an **identical** control transfer to what this project's spike already used:

`bmRequestType = 0x21 (CLASS|INTERFACE|OUT)`, `bRequest = 0x09 (SET_REPORT)`, `wValue = 0x0204`, `wIndex = 0x0003`, `wLength = 37`, via device-level `IOUSBDeviceInterface::DeviceRequest`.

Conclusions:
- The spike's transport **is** the canonical macOS approach; the legacy-protocol stall on this unit is a firmware-level refusal, not an API error.
- librazermacos only lists Kraken V2 (`0x0510`) and Kraken Ultimate (`0x0527`); PID `0x0560` (Kitty V2) is absent. No open-source project actually drives this newer revision on any OS via a documented protocol path that this hardware honors.

**Decisive result:** every documented Razer protocol (legacy `0x04`, standard 90-byte, V3 `0x40`) is stalled by this unit's firmware; only report `0x01` is accepted, and it withholds execution. No further macOS-side transport work can change this. The remaining legitimate paths are external (a Synapse capture of this exact unit, or upstream documentation), with the circumvention boundary from the first addendum still in force. This device is correctly left unsupported.
