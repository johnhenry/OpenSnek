import Foundation
import IOKit.hid
import OpenSnekCore
import OpenSnekHardware
import OpenSnekProtocols

/// Coordinates probe operations against a legacy-protocol Kraken headset over
/// its single consumer-control USB HID interface.
final class KrakenProbeClient: @unchecked Sendable {
    private let session: KrakenLegacyControlSession
    private let deviceID: String
    private let productID: Int

    init(productID preferredProductID: Int? = nil) throws {
        let pid = preferredProductID ?? 0x0560
        let enumeration = try enumerateUSBProbeCandidates(preferredProductID: pid)
        guard let best = enumeration.candidates.first else { throw ProbeError.protocolError("No USB Kraken HID interface found for pid 0x\(String(format: "%04x", pid))") }

        self.session = KrakenLegacyControlSession(device: best.device, deviceID: best.deviceID)
        self.deviceID = best.deviceID
        self.productID = best.productID
    }

    func describe() -> String { "\(deviceID) pid=0x\(String(format: "%04x", productID))" }

    func readSerial() throws -> String? {
        let request = KrakenLegacyProtocol.readEEPROMReport(address: KrakenLegacyProtocol.serialEEPROMAddress, length: KrakenLegacyProtocol.serialLength)
        let response = try session.exchange(request: request)
        guard let payload = KrakenLegacyProtocol.responsePayload(response, request: request) else { return nil }
        return KrakenLegacyProtocol.parseSerial(fromPayload: payload)
    }

    func readLEDMode() throws -> (byte: UInt8, kind: KrakenLegacyEffectKind?)? {
        let request = KrakenLegacyProtocol.readRAMReport(address: KrakenLegacyProtocol.ledModeAddress, length: 1)
        let response = try session.exchange(request: request)
        guard let payload = KrakenLegacyProtocol.responsePayload(response, request: request), let byte = payload.first else { return nil }
        return (byte, KrakenLegacyProtocol.effectKind(fromLEDModeByte: byte))
    }

    func writeEffect(_ effect: KrakenLegacyEffect) throws -> Bool { try session.perform(requests: KrakenLegacyProtocol.setEffectReports(for: effect)) }
}

/// Parses a `KrakenLegacyEffect` from the probe's `--kind`/`--color`/`--secondary` flags.
enum KrakenProbeEffectKind: String {
    case off
    case staticColor = "static"
    case spectrum
    case pulseSingle = "pulse_single"
    case pulseDual = "pulse_dual"
}

func parseKrakenLegacyEffect(kindRaw: String, primary: RGBPatch, secondary: RGBPatch) throws -> KrakenLegacyEffect {
    guard let kind = KrakenProbeEffectKind(rawValue: kindRaw) else { throw ProbeError.usage("Invalid --kind '\(kindRaw)' (expected off|static|spectrum|pulse_single|pulse_dual)") }
    switch kind {
    case .off: return .off
    case .staticColor: return .staticColor(primary)
    case .spectrum: return .spectrum
    case .pulseSingle: return .breathingSingle(primary)
    case .pulseDual: return .breathingDual(primary, secondary)
    }
}
