# Kraken Kitty V2: macOS transport and DriverKit investigation scope

## Starting point

[Contributor testing](https://github.com/gh123man/OpenSnek/pull/120#issuecomment-5625047935)
demonstrated the [V3 lighting protocol](../protocol/KRAKEN_V3_PROTOCOL.md) on Linux,
but the tested macOS API paths did not produce the requested lighting changes.
See the [transport findings](KRAKEN_KITTY_V2_MACOS_TRANSPORT_FINDINGS.md) for the
exact results and evidence limits.

Apple's HID driver was reported to own interface 3. Whether that ownership
causes the failure, and whether a custom driver would fix it, remain unproven.
This is an investigation plan, not a commitment to add a driver to OpenSnek.

## First: compare a working transaction

Capture Linux USB traffic from enumeration through one direct-mode color change
and one brightness-zero write, following the [capture guide](KRAKEN_KITTY_V2_CAPTURE_GUIDE.md).
Record all setup requests, report lengths, interface and alternate-setting
selection, and interrupt reads. Compare those with the macOS request sequence
before assigning the stalls to driver ownership.

## Then: test interface ownership if justified

A narrowly matched experimental driver could claim only `VID 0x1532`,
`PID 0x0560`, interface 3 and attempt the same known-working reports. The
contributor suggested first investigating whether a codeless matching
personality could expose the interface to a userspace client. Its feasibility
on the target macOS version has not been established; it should not be treated
as an available workaround.

If DriverKit is needed for that experiment, scope it to interface matching,
control I/O, and a small client that submits bounded lighting commands. Check
Apple's [DriverKit entitlement guidance](https://developer.apple.com/documentation/driverkit/requesting-entitlements-for-driverkit-development)
for the development and distribution requirements before planning deployment.
Do not assume that matching, entitlement approval, or distribution is already
available to this project.

## Evidence required before app integration

- Repeated visible color changes and brightness zero producing fully dark LEDs.
- Disconnect/reconnect and sleep/wake recovery without stale handles or duplicate commands.
- Continued audio, microphone, and media-key functionality on the composite device.
- Captured request bytes, OS/firmware versions, API results, and a reproducible setup.

If ownership changes do not fix delivery, return to the captured sequence and
investigate the remaining differences. Keep the device unsupported until a
working macOS transport is demonstrated; protocol research alone does not
justify registering a device profile.
