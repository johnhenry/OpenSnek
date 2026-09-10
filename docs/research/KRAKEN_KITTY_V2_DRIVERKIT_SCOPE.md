# Scoping: macOS driver to control the Kraken Kitty V2 (and V3-protocol Razer headsets)

## Why a driver is needed

The Kitty V2's lighting protocol is fully known and works (see [../protocol/KRAKEN_V3_PROTOCOL.md](../protocol/KRAKEN_V3_PROTOCOL.md)), but on macOS Apple's `IOHIDFamily` claims the device's control interface (interface 3, a consumer-page HID interface). Through the app-accessible APIs:

- `IOHIDDeviceSetReport` returns success but the vendor Output reports never reach the device.
- `IOUSBDeviceInterface` device-level control `SET_REPORT`s stall on the color/brightness commands (the interface is owned by `IOHIDFamily`; only the mode byte ACKs).

To deliver the protocol on macOS, something must **own interface 3** (or otherwise issue a real `SET_REPORT` the device honors). That is a driver, not an app change.

## Approaches, cheapest to heaviest

### 1. Codeless driver extension to steer matching (investigate first — may be insufficient)

A `.dext`/kext *personality* (Info.plist only, no code) that matches interface 3 with a higher probe score than `IOHIDFamily`, binding a permissive USB interface driver (e.g. `IOUSBHostInterface` user-client access) so the app can then open the interface via `IOUSBInterfaceInterface` and issue the control `SET_REPORT` directly.
- **Pro:** small; no custom driver logic; reuses the already-working device-level transfer code once the interface is claimable.
- **Risk:** may not be allowed to outrank `IOHIDFamily` for a HID interface without a full driver; and the observed *stall* on color commands might persist even with ownership (needs empirical test). Prove this before investing in option 2.

### 2. DriverKit USB driver (`DriverKit` / `USBDriverKit`) with an app user-client — the realistic path

A system extension that matches `VID 0x1532 / PID 0x0560 / bInterfaceNumber 3`, claims the interface, and exposes an `IOUserClient` RPC so OpenSnek can hand it lighting frames; the dext issues the `SET_REPORT` control transfers on the owned interface.

- **Components:** the dext (matching + `IOUSBHostInterface` control I/O + user-client), a small client shim in OpenSnek (`OSSystemExtension` activation, `IOServiceOpen`, RPC).
- **Entitlements / signing (the real cost):**
  - `com.apple.developer.driverkit`, `com.apple.developer.driverkit.transport.usb`, `com.apple.developer.driverkit.family.hid`/USB as applicable — these require a **DriverKit-capable Apple Developer account** (managed provisioning; Apple must approve the DriverKit entitlement request).
  - System Extensions require a Developer ID-signed, notarized host app; the user must approve the extension in System Settings (and on Apple Silicon nothing kernel-level is needed — DriverKit runs in user space, which is the point).
  - Distribution outside the App Store is fine with those entitlements + notarization.
- **Matching a device another driver wants:** the dext personality needs a probe score that wins interface 3 from `IOHIDFamily`; validate that a third-party dext is permitted to claim a consumer-HID interface (Apple sometimes reserves HID). If not, match at the *device* level and re-expose the non-lighting interfaces, which is more invasive.
- **Effort:** multi-day, plus the entitlement approval lead time from Apple. Testable only on real hardware with the signed extension installed.

### 3. Kernel extension (kext) — avoid

Legacy KPI, deprecated, requires reduced security (Recovery) to load on Apple Silicon. Not worth it versus DriverKit.

## Open technical question to resolve early

The device-level control `SET_REPORT` **stalled** for `command_id 0x03`/`0x02` (color/brightness) but ACK'd `command_id 0x01` (mode) — even though on Linux all three go over the identical `SET_REPORT`. Determine whether that stall is purely an interface-ownership artifact (goes away once a driver owns interface 3) or a genuine device quirk (e.g. requires the interface's interrupt-IN to be actively read, a specific `SET_IDLE`, or an alternate-setting selection). A cheap way to probe: on the Linux box, capture the full `usbmon` trace of a working color change and compare every setup packet and any preceding class requests (`SET_IDLE`, `SET_PROTOCOL`, `GET_REPORT`) that `usbhid` issues, then replicate them in whichever macOS driver approach is chosen.

## Recommendation

1. First, capture a complete `usbmon` trace on Linux of one color change (all URBs, including any class setup `usbhid` does) — cheap, and it de-risks options 1 and 2 by revealing whether more than the `SET_REPORT` is required.
2. Attempt option 1 (codeless matching) as a spike to see if a claimed interface + the existing control-transfer code delivers color.
3. If option 1 can't win/deliver, commit to option 2 (DriverKit) — begin the Apple DriverKit entitlement request early, since approval is the long pole.

Until a driver exists, the Kitty V2 should remain **unsupported on macOS** in OpenSnek (it correctly shows as such via the no-control-interface path), with this protocol documented for reuse.
