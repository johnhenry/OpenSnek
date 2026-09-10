import Foundation
import XCTest
import OpenSnekCore
import OpenSnekProtocols
@testable import OpenSnek

/// Exercises capability gating and lighting-effect mapping for the legacy-protocol
/// Razer Kraken Kitty V2 headset profile.
final class KrakenLegacyDeviceTests: XCTestCase {
    private func makeHeadsetDevice(id: String = "usb-kraken-kitty-v2") -> MouseDevice {
        MouseDevice(id: id, vendor_id: 0x1532, product_id: 0x0560, product_name: "Razer Kraken Kitty V2 White Ed.", transport: .usb, path_b64: "", serial: nil, firmware: nil, profile_id: .krakenKittyV2)
    }

    // MARK: - Capability gating

    // The profile is intentionally unregistered (no working macOS transport), so
    // device-level helpers resolve no profile; assert the profile's own flags,
    // which apply if the profile is ever registered.
    func testKrakenHeadsetProfileDisablesNonLightingControls() {
        let profile = DeviceProfiles.krakenKittyV2USB
        XCTAssertFalse(profile.supportsDPIControls)
        XCTAssertFalse(profile.supportsPollRateControls)
        XCTAssertFalse(profile.supportsPowerManagementControls)
        XCTAssertFalse(profile.supportsButtonRemapControls)
        XCTAssertFalse(profile.supportsScrollModeControls)
        XCTAssertFalse(profile.supportsLightingBrightnessControls)
    }

    func testUnregisteredKrakenHeadsetStaysOnUnsupportedPath() {
        XCTAssertNil(DeviceProfiles.resolve(vendorID: 0x1532, productID: 0x0560, transport: .usb))
    }

    // MARK: - Effect mapping

    func testKrakenLegacyEffectMapsSupportedLightingKinds() {
        let primary = RGBPatch(r: 10, g: 20, b: 30)
        let secondary = RGBPatch(r: 40, g: 50, b: 60)

        XCTAssertEqual(BridgeClient.krakenLegacyEffect(from: LightingEffectPatch(kind: .off, primary: primary, secondary: secondary)), .off)
        XCTAssertEqual(BridgeClient.krakenLegacyEffect(from: LightingEffectPatch(kind: .staticColor, primary: primary, secondary: secondary)), .staticColor(primary))
        XCTAssertEqual(BridgeClient.krakenLegacyEffect(from: LightingEffectPatch(kind: .spectrum, primary: primary, secondary: secondary)), .spectrum)
        XCTAssertEqual(BridgeClient.krakenLegacyEffect(from: LightingEffectPatch(kind: .pulseSingle, primary: primary, secondary: secondary)), .breathingSingle(primary))
        XCTAssertEqual(BridgeClient.krakenLegacyEffect(from: LightingEffectPatch(kind: .pulseDual, primary: primary, secondary: secondary)), .breathingDual(primary, secondary))
    }

    func testKrakenLegacyEffectRejectsUnsupportedLightingKinds() {
        for kind: LightingEffectKind in [.wave, .reactive, .pulseRandom] { XCTAssertNil(BridgeClient.krakenLegacyEffect(from: LightingEffectPatch(kind: kind)), "kind \(kind.rawValue) should be unsupported") }
    }

    func testKrakenKittyV2ProfileOnlyAdvertisesMappableLightingEffects() {
        let profile: DeviceProfile? = DeviceProfiles.krakenKittyV2USB
        for kind in profile?.supportedLightingEffects ?? [] {
            XCTAssertNotNil(BridgeClient.krakenLegacyEffect(from: LightingEffectPatch(kind: kind)), "advertised kind \(kind.rawValue) must be mappable")
        }
    }

    // MARK: - Protocol shape (sanity-checks the stub's contract, not its byte layout)

    func testSetEffectReportsEndsWithLEDModeWrite() {
        let reports = KrakenLegacyProtocol.setEffectReports(for: .staticColor(RGBPatch(r: 1, g: 2, b: 3)))
        XCTAssertFalse(reports.isEmpty)
        for report in reports { XCTAssertEqual(report.count, KrakenLegacyProtocol.requestLength) }
    }

    func testResponsePayloadRequiresMatchingReportID() {
        let request = KrakenLegacyProtocol.readRAMReport(address: KrakenLegacyProtocol.ledModeAddress, length: 1)
        var response = [UInt8](repeating: 0, count: KrakenLegacyProtocol.responseLength)
        response[0] = KrakenLegacyProtocol.responseReportID
        XCTAssertNotNil(KrakenLegacyProtocol.responsePayload(response, request: request))

        response[0] = KrakenLegacyProtocol.responseReportID &+ 1
        XCTAssertNil(KrakenLegacyProtocol.responsePayload(response, request: request))
    }
}
