import Foundation
import OpenSnekCore
import OpenSnekHardware
import OpenSnekProtocols

/// Adds legacy-protocol Kraken headset routing to `BridgeClient`.
///
/// Kraken headsets (e.g. Kraken Kitty V2) expose only a single consumer-control
/// USB HID interface, so they cannot answer the standard Razer class/cmd
/// feature-report protocol every other USB profile uses. Every entry point here
/// is reached only when `DeviceProfile.usesKrakenLegacyProtocol` is true, guarded
/// by the call sites in `BridgeClient.swift`, `BridgeClient+USB.swift`, and
/// `BridgeClient+Apply.swift` before they fall through to the standard USB path.
extension BridgeClient {
    func krakenLegacySession(for device: MouseDevice) -> KrakenLegacyControlSession? { krakenSessionsByDeviceID[device.id] }

    /// True when either a serial or an LED-mode read answers, i.e. the headset
    /// is present and its control interface is responding.
    func krakenLegacyIsReachable(_ session: KrakenLegacyControlSession) -> Bool {
        (try? krakenLegacyReadSerial(session)) != nil || (try? krakenLegacyReadLEDModeByte(session)) != nil
    }

    func krakenLegacyControlAvailability(device: MouseDevice) async throws -> USBControlAvailability {
        guard let session = krakenLegacySession(for: device) else {
            if managerAccessDenied { throw BridgeError.commandFailed("USB HID access denied by macOS. Enable Input Monitoring for OpenSnek " + "(or Terminal/Xcode when running via swift run/Xcode), then relaunch.") }
            return .receiverAbsent
        }

        do {
            let reachable = try session.withExclusiveDeviceAccess { krakenLegacyIsReachable(session) }
            if reachable { return .receiverPresentMouseReachable }
        } catch {
            if let bridgeError = error as? BridgeError, case .commandFailed(let message) = bridgeError, message.contains("USB HID access denied") { throw error }
            AppLog.debug("Bridge", "krakenLegacyControlAvailability probe failed device=\(device.id): \(error.localizedDescription)")
        }

        if await usbDeviceIsAbsentAfterDiscoveryRefresh(device: device, operation: "kraken-control-availability") { return .receiverAbsent }
        return .receiverPresentMouseUnavailable
    }

    func readKrakenLegacyState(device: MouseDevice) async throws -> MouseState {
        guard let session = krakenSessionsByDeviceID[device.id] else {
            if managerAccessDenied { throw BridgeError.commandFailed("USB HID access denied by macOS. Enable Input Monitoring for OpenSnek " + "(or Terminal/Xcode when running via swift run/Xcode), then relaunch.") }
            throw BridgeError.commandFailed("Device not available")
        }

        return try session.withExclusiveDeviceAccess {
            let serial = try? krakenLegacyReadSerial(session)
            let ledModeByte = try? krakenLegacyReadLEDModeByte(session)
            guard serial != nil || ledModeByte != nil else { throw BridgeError.usbMouseUnavailable }

            let profile = usbDeviceProfile(for: device)
            let capabilities = Capabilities(dpi_stages: false, poll_rate: false, power_management: false, button_remap: false, lighting: true)
            _ = profile

            return MouseState(
                device: DeviceSummary(id: device.id, product_name: device.product_name, serial: serial ?? device.serial, transport: device.transport, firmware: device.firmware), connection: "USB", battery_percent: nil, charging: nil, dpi: nil,
                dpi_stages: DpiStages(active_stage: nil, values: nil), poll_rate: nil, sleep_timeout: nil, device_mode: nil, led_value: ledModeByte.map(Int.init), capabilities: capabilities)
        }
    }

    func applyKrakenLegacyUSB(device: MouseDevice, patch: DevicePatch) async throws -> MouseState {
        guard let session = krakenSessionsByDeviceID[device.id] else {
            if managerAccessDenied { throw BridgeError.commandFailed("USB HID access denied by macOS. Enable Input Monitoring for OpenSnek " + "(or Terminal/Xcode when running via swift run/Xcode), then relaunch.") }
            throw BridgeError.commandFailed("Device not available")
        }

        if let rgb = patch.ledRGB {
            let effect = KrakenLegacyEffect.staticColor(rgb)
            guard try session.withExclusiveDeviceAccess({ try session.perform(requests: KrakenLegacyProtocol.setEffectReports(for: effect)) }) else { throw BridgeError.commandFailed("Failed to set Kraken LED color") }
        }

        if let effectPatch = patch.lightingEffect {
            guard let effect = Self.krakenLegacyEffect(from: effectPatch) else { throw BridgeError.commandFailed("Unsupported lighting effect for this device") }
            guard try session.withExclusiveDeviceAccess({ try session.perform(requests: KrakenLegacyProtocol.setEffectReports(for: effect)) }) else { throw BridgeError.commandFailed("Failed to set Kraken lighting effect") }
        }

        return try await readKrakenLegacyState(device: device)
    }

    /// Maps a UI-facing lighting patch to the legacy Kraken protocol's effect
    /// enum. Only the effects `krakenKittyV2USB` advertises are reachable here;
    /// anything else (wave, reactive, pulseRandom, breathingTriple) is rejected.
    nonisolated static func krakenLegacyEffect(from patch: LightingEffectPatch) -> KrakenLegacyEffect? {
        switch patch.kind {
        case .off: return .off
        case .staticColor: return .staticColor(patch.primary)
        case .spectrum: return .spectrum
        case .pulseSingle: return .breathingSingle(patch.primary)
        case .pulseDual: return .breathingDual(patch.primary, patch.secondary)
        case .wave, .reactive, .pulseRandom: return nil
        }
    }

    private func krakenLegacyReadSerial(_ session: KrakenLegacyControlSession) throws -> String? {
        let request = KrakenLegacyProtocol.readEEPROMReport(address: KrakenLegacyProtocol.serialEEPROMAddress, length: KrakenLegacyProtocol.serialLength)
        let response = try session.exchange(request: request)
        guard let payload = KrakenLegacyProtocol.responsePayload(response, request: request) else { return nil }
        return KrakenLegacyProtocol.parseSerial(fromPayload: payload)
    }

    private func krakenLegacyReadLEDModeByte(_ session: KrakenLegacyControlSession) throws -> UInt8? {
        let request = KrakenLegacyProtocol.readRAMReport(address: KrakenLegacyProtocol.ledModeAddress, length: 1)
        let response = try session.exchange(request: request)
        guard let payload = KrakenLegacyProtocol.responsePayload(response, request: request), let byte = payload.first else { return nil }
        return byte
    }
}
