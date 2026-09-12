import Foundation
import XCTest
import OpenSnekAppSupport
import OpenSnekCore
@testable import OpenSnek

/// Verifies saved settings for USB profiles across disconnect and reconnect.
final class AppStateWiredMouseRestoreTests: XCTestCase {
    func testBasiliskRestoreOmitsPowerCommandsAcrossReconnect() async throws { try await verifyRestoreAcrossReconnect(profile: DeviceProfiles.basiliskUSB) }

    func testLanceheadRestoreOmitsPowerCommandsAcrossReconnect() async throws { try await verifyRestoreAcrossReconnect(profile: DeviceProfiles.lanceheadTEUSB) }

    func testHuntsmanRestoreOmitsMouseCommandsAcrossReconnect() async throws { try await verifyRestoreAcrossReconnect(profile: DeviceProfiles.huntsmanMiniUSB) }

    func testTartarusRestoreOmitsMouseCommandsAcrossReconnect() async throws { try await verifyRestoreAcrossReconnect(profile: DeviceProfiles.tartarusProUSB) }

    func testLightingOnlyAvailabilityRequiresBrightnessDuringInitialReadAndRecovery() async throws {
        let appState = await MainActor.run { AppState(launchRole: .app, backend: AppStateRefactorStubBackend(devices: [], stateByDeviceID: [:]), autoStart: false) }
        for profile in [DeviceProfiles.huntsmanMiniUSB, DeviceProfiles.tartarusProUSB] {
            let device = try makeDevice(profile: profile)
            let healthy = makeLiveState(device: device, profile: profile)
            let incomplete = makeLiveState(device: device, profile: profile, brightness: nil)
            await MainActor.run {
                for recovering in [false, true] {
                    XCTAssertFalse(appState.deviceController.shouldTreatPartialUSBTelemetryAsUnavailable(healthy, device: device, wasRecoveringUSBBackoff: recovering, hasCachedState: recovering))
                    XCTAssertTrue(appState.deviceController.shouldTreatPartialUSBTelemetryAsUnavailable(incomplete, device: device, wasRecoveringUSBBackoff: recovering, hasCachedState: recovering))
                }
            }
        }
    }

    private func verifyRestoreAcrossReconnect(profile: DeviceProfile) async throws {
        let device = try makeDevice(profile: profile)
        let color = RGBColor(r: 11, g: 22, b: 33)
        let preferences = DevicePreferenceStore()
        preferences.persistConnectBehavior(.restoreOpenSnekSettings, device: device)
        preferences.persistDeviceSettingsSnapshot(makeRefactorSettingsSnapshot(color: color), device: device)
        defer { clearRefactorPreferences(for: device) }

        let state = makeLiveState(device: device, profile: profile)
        let backend = AppStateRefactorStubBackend(devices: [device], stateByDeviceID: [device.id: state])
        let appState = await MainActor.run { AppState(launchRole: .app, backend: backend, autoStart: false) }
        await appState.deviceStore.refreshDevices()
        try await waitForRefactorCondition { await backend.applyCount() >= 1 }
        let initialPatches = await backend.recordedPatches()
        assertSupportedRestore(try XCTUnwrap(initialPatches.first), color: color, profile: profile)

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
        assertSupportedRestore(try XCTUnwrap(reconnectedPatches.last), color: color, profile: profile)
        await MainActor.run {
            XCTAssertEqual(appState.deviceStore.selectedDeviceID, device.id)
            XCTAssertEqual(appState.deviceStore.state?.dpi_stages.active_stage, profile.supportsDPIControls ? 1 : nil)
        }
    }

    private func makeDevice(profile: DeviceProfile) throws -> MouseDevice {
        MouseDevice(
            id: "wired-restore-\(profile.id.rawValue)", vendor_id: 0x1532, product_id: try XCTUnwrap(profile.supportedProducts.first), product_name: profile.productName, transport: .usb, path_b64: "", serial: "WIRED-RESTORE-\(UUID().uuidString)", firmware: nil, profile_id: profile.id,
            button_layout: profile.buttonLayout, supports_advanced_lighting_effects: profile.supportsAdvancedLightingEffects, onboard_profile_count: profile.onboardProfileCount)
    }

    private func makeLiveState(device: MouseDevice, profile: DeviceProfile, brightness: Int? = 77) -> MouseState {
        MouseState(
            device: DeviceSummary(id: device.id, product_name: device.product_name, serial: device.serial, transport: .usb, firmware: nil), connection: "USB", battery_percent: nil, charging: nil, dpi: profile.supportsDPIControls ? DpiPair(x: 1600, y: 1600) : nil,
            dpi_stages: DpiStages(active_stage: profile.supportsDPIControls ? 1 : nil, values: profile.supportsDPIControls ? [800, 1600, 3200] : []), poll_rate: profile.supportsPollRateControls ? 500 : nil, sleep_timeout: nil, device_mode: nil, led_value: brightness,
            capabilities: Capabilities(dpi_stages: profile.supportsDPIControls, poll_rate: profile.supportsPollRateControls, power_management: false, button_remap: false, lighting: true))
    }

    private func assertSupportedRestore(_ patch: DevicePatch, color: OpenSnekCore.RGBColor, profile: DeviceProfile) {
        XCTAssertNil(patch.sleepTimeout)
        XCTAssertNil(patch.lowBatteryThresholdRaw)
        XCTAssertNil(patch.buttonBinding)
        XCTAssertEqual(patch.pollRate, profile.supportsPollRateControls ? 500 : nil)
        XCTAssertEqual(patch.dpiStages, profile.supportsDPIControls ? [900, 1800, 3600] : nil)
        XCTAssertEqual(patch.affectsDpiStages, profile.supportsDPIControls)
        XCTAssertNil(patch.activeStage)
        XCTAssertEqual(patch.ledRGB ?? patch.lightingEffect?.primary, RGBPatch(r: color.r, g: color.g, b: color.b))
    }
}
