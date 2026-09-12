import Foundation
import XCTest
import OpenSnekAppSupport
import OpenSnekCore
@testable import OpenSnek

/// Verifies saved settings for wired mice across disconnect and reconnect.
final class AppStateWiredMouseRestoreTests: XCTestCase {
    func testBasiliskRestoreOmitsPowerCommandsAcrossReconnect() async throws { try await verifyRestoreAcrossReconnect(profile: DeviceProfiles.basiliskUSB) }

    func testLanceheadRestoreOmitsPowerCommandsAcrossReconnect() async throws { try await verifyRestoreAcrossReconnect(profile: DeviceProfiles.lanceheadTEUSB) }

    private func verifyRestoreAcrossReconnect(profile: DeviceProfile) async throws {
        let device = try makeDevice(profile: profile)
        let color = RGBColor(r: 11, g: 22, b: 33)
        let preferences = DevicePreferenceStore()
        preferences.persistConnectBehavior(.restoreOpenSnekSettings, device: device)
        preferences.persistDeviceSettingsSnapshot(makeRefactorSettingsSnapshot(color: color), device: device)
        defer { clearRefactorPreferences(for: device) }

        let state = makeRefactorTestState(device: device, telemetry: RefactorTestStateTelemetry(connection: "usb", batteryPercent: 0, dpiValues: [800, 1600, 3200], activeStage: 1))
        let backend = AppStateRefactorStubBackend(devices: [device], stateByDeviceID: [device.id: state])
        let appState = await MainActor.run { AppState(launchRole: .app, backend: backend, autoStart: false) }
        await appState.deviceStore.refreshDevices()
        try await waitForRefactorCondition { await backend.applyCount() >= 1 }
        let initialPatches = await backend.recordedPatches()
        assertSupportedRestore(try XCTUnwrap(initialPatches.first), color: color)

        await MainActor.run {
            appState.deviceController.applyDeviceList([], source: "test.disconnect")
            XCTAssertTrue(appState.deviceStore.devices.isEmpty)
            XCTAssertNil(appState.deviceStore.selectedDevice)
        }
        let offlineApplyCount = await backend.applyCount()
        await appState.deviceController.restorePersistedSettingsIfNeeded(for: device)
        let afterOfflineApplyCount = await backend.applyCount()
        XCTAssertEqual(afterOfflineApplyCount, offlineApplyCount)

        await backend.setState(state, forDeviceID: device.id)
        await appState.deviceStore.refreshDevices()
        try await waitForRefactorCondition { await backend.applyCount() > offlineApplyCount }
        let reconnectedPatches = await backend.recordedPatches()
        assertSupportedRestore(try XCTUnwrap(reconnectedPatches.last), color: color)
        await MainActor.run {
            XCTAssertEqual(appState.deviceStore.selectedDeviceID, device.id)
            XCTAssertEqual(appState.deviceStore.state?.dpi_stages.active_stage, 1)
        }
    }

    private func makeDevice(profile: DeviceProfile) throws -> MouseDevice {
        MouseDevice(
            id: "wired-restore-\(profile.id.rawValue)", vendor_id: 0x1532, product_id: try XCTUnwrap(profile.supportedProducts.first), product_name: profile.productName, transport: .usb, path_b64: "", serial: "WIRED-RESTORE-\(UUID().uuidString)", firmware: nil, profile_id: profile.id,
            button_layout: profile.buttonLayout, supports_advanced_lighting_effects: profile.supportsAdvancedLightingEffects, onboard_profile_count: profile.onboardProfileCount)
    }

    private func assertSupportedRestore(_ patch: DevicePatch, color: OpenSnekCore.RGBColor) {
        XCTAssertNil(patch.sleepTimeout)
        XCTAssertNil(patch.lowBatteryThresholdRaw)
        XCTAssertNil(patch.buttonBinding)
        XCTAssertEqual(patch.pollRate, 500)
        XCTAssertEqual(patch.dpiStages, [900, 1800, 3600])
        XCTAssertNil(patch.activeStage)
        XCTAssertEqual(patch.ledRGB ?? patch.lightingEffect?.primary, RGBPatch(r: color.r, g: color.g, b: color.b))
    }
}
