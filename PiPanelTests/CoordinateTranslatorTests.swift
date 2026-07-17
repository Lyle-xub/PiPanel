import XCTest
@testable import PiPanel

private actor TopologyConcurrencyProbe {
    private var activeOperations = 0
    private(set) var maximumConcurrentOperations = 0

    func enter() {
        activeOperations += 1
        maximumConcurrentOperations = max(maximumConcurrentOperations, activeOperations)
    }

    func leave() {
        activeOperations -= 1
    }
}

final class VirtualDisplayCoordinatorTests: XCTestCase {
    func testTopologyOperationsAreStrictlySerialized() async {
        let coordinator = VirtualDisplayCoordinator()
        let probe = TopologyConcurrencyProbe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    await coordinator.lock()
                    await probe.enter()
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    await probe.leave()
                    await coordinator.unlock()
                }
            }
        }

        let maximum = await probe.maximumConcurrentOperations
        XCTAssertEqual(maximum, 1)
    }
}

final class PiPActivationMethodTests: XCTestCase {
    func testShakeFallsBackToCornerSwitchWithoutProAccess() {
        XCTAssertEqual(
            PiPActivationMethod.shake.resolved(hasProAccess: false),
            PiPActivationMethod.cornerSwitch
        )
    }

    func testShakeIsAvailableWithTrialOrPermanentProAccess() {
        XCTAssertEqual(
            PiPActivationMethod.shake.resolved(hasProAccess: true),
            PiPActivationMethod.shake
        )
    }

    func testCornerSwitchNeverRequiresLicense() {
        XCTAssertEqual(
            PiPActivationMethod.cornerSwitch.resolved(hasProAccess: false),
            PiPActivationMethod.cornerSwitch
        )
    }
}

final class SettingsStoreTests: XCTestCase {
    @MainActor
    func testNewInstallUsesLowerResourceDefaultsAndCornerCloseButton() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(userDefaults: defaults)

        XCTAssertEqual(settings.virtualDisplayLongEdge, 1664)
        let virtualDisplaySize = VirtualDisplayHost.pixelSize(
            forLongEdge: settings.virtualDisplayLongEdge
        )
        XCTAssertEqual(virtualDisplaySize.width, 1664)
        XCTAssertEqual(virtualDisplaySize.height, 1040)
        XCTAssertEqual(settings.captureOutputLongEdge, 960)
        XCTAssertEqual(settings.panelCloseMethod, .cornerButton)
    }

    @MainActor
    func testOriginalMinimumVirtualDisplayResolutionRemainsAvailable() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(1280.0, forKey: "settings.virtualDisplayLongEdge")

        let settings = SettingsStore(userDefaults: defaults)

        XCTAssertEqual(
            settings.virtualDisplayLongEdge,
            1280
        )
        XCTAssertEqual(
            defaults.double(forKey: "settings.virtualDisplayLongEdge"),
            1280
        )
    }

    @MainActor
    func testResetRestoresEveryUserFacingSettingAndPersistsDefaults() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(userDefaults: defaults)

        settings.targetFPS = 48
        settings.virtualDisplayLongEdge = SettingsStore.minimumVirtualDisplayLongEdge
        settings.captureOutputLongEdge = 2560
        settings.autoReturnEnabled = true
        settings.autoReturnIdleInterval = 5
        settings.autoStackOnIdleEnabled = true
        settings.autoStackIdleInterval = 300
        settings.autoHideWhenSourceActive = false
        settings.hasCompletedWelcome = true
        settings.defaultPanelWidth = 600
        settings.defaultStackingCorner = .bottomLeft
        settings.panelCornerRadius = 24
        settings.panelShadowEnabled = false
        settings.edgeHandleColorHex = "123456"
        settings.edgeHandleWidth = 20
        settings.edgeHandleHeight = 120
        settings.stackCascadeStep = 30
        settings.stackCascadeMargin = 48
        settings.stackMaxVisibleDepth = 10
        settings.panelAppearRippleEnabled = false
        settings.panelBackgroundColorHex = "654321"
        settings.panelBorderStyle = .glow
        settings.panelBorderColorHex = "ABCDEF"
        settings.panelBorderGradientEndColorHex = "FEDCBA"
        settings.panelBorderWidth = 6
        settings.panelTitleEnabled = true
        settings.panelOpacity = 0.2
        settings.panelLyricsEnabled = false
        settings.panelCloseMethod = .dragToZone
        settings.pipActivationMethod = .shake
        settings.stackShortcut = nil
        settings.closeAllShortcut = nil
        settings.pipAllShortcut = nil

        settings.resetToDefaults()

        assertDefaultSettings(settings)
        XCTAssertTrue(settings.hasCompletedWelcome)

        let reloaded = SettingsStore(userDefaults: defaults)
        assertDefaultSettings(reloaded)
        XCTAssertTrue(reloaded.hasCompletedWelcome)
    }

    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "PiPanelTests.SettingsStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    @MainActor
    private func assertDefaultSettings(
        _ settings: SettingsStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let values = SettingsStore.DefaultValues.self
        XCTAssertEqual(settings.targetFPS, values.targetFPS, file: file, line: line)
        XCTAssertEqual(
            settings.virtualDisplayLongEdge,
            values.virtualDisplayLongEdge,
            file: file,
            line: line
        )
        XCTAssertEqual(
            settings.captureOutputLongEdge,
            values.captureOutputLongEdge,
            file: file,
            line: line
        )
        XCTAssertEqual(settings.autoReturnEnabled, values.autoReturnEnabled, file: file, line: line)
        XCTAssertEqual(
            settings.autoReturnIdleInterval,
            values.autoReturnIdleInterval,
            file: file,
            line: line
        )
        XCTAssertEqual(
            settings.autoStackOnIdleEnabled,
            values.autoStackOnIdleEnabled,
            file: file,
            line: line
        )
        XCTAssertEqual(
            settings.autoStackIdleInterval,
            values.autoStackIdleInterval,
            file: file,
            line: line
        )
        XCTAssertEqual(
            settings.autoHideWhenSourceActive,
            values.autoHideWhenSourceActive,
            file: file,
            line: line
        )
        XCTAssertEqual(settings.defaultPanelWidth, values.defaultPanelWidth, file: file, line: line)
        XCTAssertEqual(
            settings.defaultStackingCorner,
            values.defaultStackingCorner,
            file: file,
            line: line
        )
        XCTAssertEqual(settings.panelCornerRadius, values.panelCornerRadius, file: file, line: line)
        XCTAssertEqual(settings.panelShadowEnabled, values.panelShadowEnabled, file: file, line: line)
        XCTAssertEqual(settings.edgeHandleColorHex, values.edgeHandleColorHex, file: file, line: line)
        XCTAssertEqual(settings.edgeHandleWidth, values.edgeHandleWidth, file: file, line: line)
        XCTAssertEqual(settings.edgeHandleHeight, values.edgeHandleHeight, file: file, line: line)
        XCTAssertEqual(settings.stackCascadeStep, values.stackCascadeStep, file: file, line: line)
        XCTAssertEqual(settings.stackCascadeMargin, values.stackCascadeMargin, file: file, line: line)
        XCTAssertEqual(
            settings.stackMaxVisibleDepth,
            values.stackMaxVisibleDepth,
            file: file,
            line: line
        )
        XCTAssertEqual(
            settings.panelAppearRippleEnabled,
            values.panelAppearRippleEnabled,
            file: file,
            line: line
        )
        XCTAssertEqual(
            settings.panelBackgroundColorHex,
            values.panelBackgroundColorHex,
            file: file,
            line: line
        )
        XCTAssertEqual(settings.panelBorderStyle, values.panelBorderStyle, file: file, line: line)
        XCTAssertEqual(
            settings.panelBorderColorHex,
            values.panelBorderColorHex,
            file: file,
            line: line
        )
        XCTAssertEqual(
            settings.panelBorderGradientEndColorHex,
            values.panelBorderGradientEndColorHex,
            file: file,
            line: line
        )
        XCTAssertEqual(settings.panelBorderWidth, values.panelBorderWidth, file: file, line: line)
        XCTAssertEqual(settings.panelTitleEnabled, values.panelTitleEnabled, file: file, line: line)
        XCTAssertEqual(settings.panelOpacity, values.panelOpacity, file: file, line: line)
        XCTAssertEqual(settings.panelLyricsEnabled, values.panelLyricsEnabled, file: file, line: line)
        XCTAssertEqual(settings.panelCloseMethod, values.panelCloseMethod, file: file, line: line)
        XCTAssertEqual(
            settings.pipActivationMethod,
            values.pipActivationMethod,
            file: file,
            line: line
        )
        XCTAssertEqual(settings.stackShortcut, values.stackShortcut, file: file, line: line)
        XCTAssertEqual(settings.closeAllShortcut, values.closeAllShortcut, file: file, line: line)
        XCTAssertEqual(settings.pipAllShortcut, values.pipAllShortcut, file: file, line: line)
    }
}

final class DeviceIdentityTests: XCTestCase {
    func testHardwareIdentifierHashIsStableAndDoesNotExposeRawIdentifier() {
        let rawIdentifier = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let first = DeviceIdentity.hashedIdentifier(rawIdentifier)
        let second = DeviceIdentity.hashedIdentifier(rawIdentifier)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 64)
        XCTAssertNotEqual(first.lowercased(), rawIdentifier.lowercased())
        XCTAssertTrue(first.allSatisfy { $0.isHexDigit })
    }

    func testActivationNameUsesStableDigestAndStaysWithinCreemLimit() {
        let deviceID = DeviceIdentity.hashedIdentifier("stable-hardware-id")
        let name = DeviceIdentity.activationName(
            hostName: String(repeating: "MacBook-Pro-", count: 10),
            deviceID: deviceID
        )

        XCTAssertLessThanOrEqual(name.count, 80)
        XCTAssertTrue(name.hasSuffix(" · \(deviceID.prefix(12).uppercased())"))
    }
}

final class PanelPlacementAnchorTests: XCTestCase {
    func testTopRightAnchorSurvivesPhysicalScreenOriginChange() {
        let anchor = PanelPlacementAnchor(
            frame: CGRect(x: 3068, y: 747, width: 340, height: 205),
            visibleFrame: CGRect(x: 1512, y: -98, width: 1920, height: 1050),
            corner: .topRight
        )

        let corrected = anchor.frame(
            in: CGRect(x: 1512, y: 0, width: 1920, height: 1050)
        )

        XCTAssertEqual(corrected, CGRect(x: 3068, y: 845, width: 340, height: 205))
    }

    func testBottomLeftAnchorPreservesStackSlotInsets() {
        let anchor = PanelPlacementAnchor(
            frame: CGRect(x: 1536, y: 250, width: 340, height: 205),
            visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1050),
            corner: .bottomLeft
        )

        let corrected = anchor.frame(
            in: CGRect(x: -1920, y: -120, width: 1920, height: 1080)
        )

        XCTAssertEqual(corrected, CGRect(x: -1896, y: 130, width: 340, height: 205))
    }
}

final class VirtualDisplayIntrusionPolicyTests: XCTestCase {
    private let managed = CGRect(x: 1920, y: 0, width: 1280, height: 800)

    func testWindowCenteredOnManagedDisplayIsDetected() {
        let frame = CGRect(x: 2000, y: 100, width: 900, height: 600)
        XCTAssertTrue(
            VirtualDisplayIntrusionPolicy.occupiesManagedDisplay(frame, managedFrames: [managed])
        )
    }

    func testHarmlessEdgeSliverIsNotDetected() {
        let frame = CGRect(x: 1000, y: 100, width: 1000, height: 600)
        XCTAssertFalse(
            VirtualDisplayIntrusionPolicy.occupiesManagedDisplay(frame, managedFrames: [managed])
        )
    }

    func testRecoveryPrefersLastKnownPhysicalFrame() {
        let current = CGRect(x: 2100, y: 100, width: 800, height: 600)
        let lastSafe = CGRect(x: 200, y: 120, width: 800, height: 600)
        let physical = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        XCTAssertEqual(
            VirtualDisplayIntrusionPolicy.recoveryFrame(
                for: current,
                lastSafeFrame: lastSafe,
                physicalFrames: [physical]
            ),
            lastSafe
        )
    }

    func testRecoveryWithoutHistoryClampsWindowOntoNearestPhysicalDisplay() {
        let current = CGRect(x: 3300, y: 900, width: 800, height: 600)
        let physical = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let recovered = VirtualDisplayIntrusionPolicy.recoveryFrame(
            for: current,
            lastSafeFrame: nil,
            physicalFrames: [physical]
        )

        XCTAssertEqual(recovered, CGRect(x: 1096, y: 456, width: 800, height: 600))
    }
}

final class VirtualDisplayPoolPolicyTests: XCTestCase {
    func testOnlyTwoDisplaysArePrewarmedAtLaunch() {
        XCTAssertEqual(VirtualDisplayPoolPolicy.initialWarmCapacity, 2)
    }

    func testFirstThreeReusableDisplaysRemainWarm() {
        XCTAssertTrue(
            VirtualDisplayPoolPolicy.shouldRetainReleasedDisplay(
                reusable: true,
                currentPoolCount: 3
            )
        )
    }

    func testDisplayBeyondWarmCapacityIsReclaimed() {
        XCTAssertFalse(
            VirtualDisplayPoolPolicy.shouldRetainReleasedDisplay(
                reusable: true,
                currentPoolCount: 4
            )
        )
    }

    func testContaminatedDisplayIsAlwaysReclaimed() {
        XCTAssertFalse(
            VirtualDisplayPoolPolicy.shouldRetainReleasedDisplay(
                reusable: false,
                currentPoolCount: 2
            )
        )
    }
}

final class CoordinateTranslatorTests: XCTestCase {
    func testDisplayRefreshRateUsesFastestCurrentDisplay() {
        XCTAssertEqual(DisplayRefreshRate.maximumFPS(from: [60, 120, 144]), 144)
    }

    func testDisplayRefreshRateFallsBackWhenSystemReportsNoRate() {
        XCTAssertEqual(DisplayRefreshRate.maximumFPS(from: [0, -1]), 60)
    }

    func testCaptureFrameRateIsLimitedByCaptureAndPresentationDisplays() {
        XCTAssertEqual(CaptureSession.effectiveFrameRate(requested: 144, displayMaximum: 60), 60)
        XCTAssertEqual(CaptureSession.effectiveFrameRate(requested: 120, displayMaximum: 144), 120)
        XCTAssertEqual(
            CaptureSession.effectiveFrameRate(
                requested: 144,
                captureMaximum: 144,
                presentationMaximum: 144
            ),
            144
        )
        XCTAssertEqual(
            CaptureSession.effectiveFrameRate(
                requested: 144,
                captureMaximum: 144,
                presentationMaximum: 60
            ),
            60
        )
    }

    func testDockIsAlwaysExcludedFromVirtualDisplayCapture() {
        XCTAssertTrue(CaptureSession.excludesSystemUI(bundleIdentifier: "com.apple.dock"))
        XCTAssertFalse(CaptureSession.excludesSystemUI(bundleIdentifier: "com.apple.finder"))
        XCTAssertFalse(CaptureSession.excludesSystemUI(bundleIdentifier: nil))
    }

    func testSourceWindowIsNotExceptedWhenOnlyDockIsExcluded() {
        XCTAssertFalse(
            CaptureSession.shouldExceptSourceWindow(
                sourceProcessID: 100,
                excludedApplicationProcessIDs: [200]
            )
        )
    }

    func testSourceWindowIsExceptedWhenSiblingBelongsToSameApplication() {
        XCTAssertTrue(
            CaptureSession.shouldExceptSourceWindow(
                sourceProcessID: 100,
                excludedApplicationProcessIDs: [100, 200]
            )
        )
    }

    func testInitialSourceWindowKeepsDockTriggerZoneClear() {
        let fitted = CaptureSession.sourceSizeFittingSafeArea(
            CGSize(width: 1600, height: 1000),
            displaySize: CGSize(width: 1280, height: 800),
            localOrigin: CGPoint(x: 40, y: 44)
        )

        XCTAssertEqual(fitted.width, 1081.6, accuracy: 0.001)
        XCTAssertEqual(fitted.height, 676, accuracy: 0.001)
        XCTAssertLessThanOrEqual(
            44 + fitted.height + CaptureSession.dockAvoidanceInset,
            800
        )
    }

    func testOversizedElectronWindowRequiresExpandedDisplay() {
        let sourceFrame = CGRect(x: 40, y: 44, width: 1120, height: 678)
        let required = CaptureSession.requiredDisplaySize(forSourceFrame: sourceFrame)

        XCTAssertEqual(required, CGSize(width: 1200, height: 802))
        XCTAssertFalse(
            CaptureSession.sourceFrameFitsSafeArea(
                sourceFrame,
                displaySize: CGSize(width: 1081.6, height: 676)
            )
        )
        XCTAssertTrue(
            CaptureSession.sourceFrameFitsSafeArea(
                sourceFrame,
                displaySize: CGSize(width: 1283.75, height: 802.75)
            )
        )
    }

    func testNativeFullScreenCaptureUsesEntireRawVirtualDisplay() {
        let rect = CaptureSession.nativeFullScreenCaptureRect(
            displaySize: CGSize(width: 2560, height: 1600)
        )

        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 2560, height: 1600))
    }

    func testCaptureCanvasUsesWindowServerRegistrationInsteadOfRequestedMode() {
        let size = VirtualDisplayHost.captureCanvasSize(
            registeredSize: CGSize(width: 2560, height: 1600),
            fallbackModeSize: CGSize(width: 1280, height: 800)
        )

        XCTAssertEqual(size, CGSize(width: 2560, height: 1600))
    }

    func testCaptureCanvasFallsBackWhileDisplayIsStillRegistering() {
        let size = VirtualDisplayHost.captureCanvasSize(
            registeredSize: .zero,
            fallbackModeSize: CGSize(width: 1280, height: 800)
        )

        XCTAssertEqual(size, CGSize(width: 1280, height: 800))
    }

    func testCaptureCanvasUsesLargerLiveModeAfterResize() {
        let size = VirtualDisplayHost.captureCanvasSize(
            registeredSize: CGSize(width: 1664, height: 1040),
            fallbackModeSize: CGSize(width: 1975, height: 1235)
        )

        XCTAssertEqual(size, CGSize(width: 1975, height: 1235))
    }

    func testVirtualDisplayModeGrowsEnoughForBilibiliMinimumSize() {
        let pixelSize = VirtualDisplayHost.pixelSizeFitting(
            coordinateSize: CGSize(width: 1200, height: 802),
            pointsPerPixel: CGSize(width: 0.65, height: 0.65),
            minimumPixelSize: CGSize(width: 1664, height: 1040)
        )

        XCTAssertEqual(pixelSize, CGSize(width: 1975, height: 1235))
        let coordinateSize = VirtualDisplayHost.coordinateSize(
            pixelSize: pixelSize!,
            pointsPerPixel: CGSize(width: 0.65, height: 0.65)
        )
        XCTAssertGreaterThanOrEqual(coordinateSize.width, 1200)
        XCTAssertGreaterThanOrEqual(coordinateSize.height, 802)
    }

    func testVirtualDisplayModeRejectsWindowBeyondDescriptorCeiling() {
        XCTAssertNil(
            VirtualDisplayHost.pixelSizeFitting(
                coordinateSize: CGSize(width: 2000, height: 1400),
                pointsPerPixel: CGSize(width: 0.65, height: 0.65),
                minimumPixelSize: CGSize(width: 1664, height: 1040)
            )
        )
    }

    func testFullscreenLikeWindowWithoutAXFlagUsesRawDisplayCapture() {
        XCTAssertTrue(
            CaptureSession.isFullVirtualDisplayFrame(
                CGRect(x: 1920, y: 30, width: 2560, height: 1570),
                displayOrigin: CGPoint(x: 1920, y: 0),
                displayPixelSize: CGSize(width: 2560, height: 1600)
            )
        )
    }

    func testOrdinaryWindowIsNotMistakenForFullscreen() {
        XCTAssertFalse(
            CaptureSession.isFullVirtualDisplayFrame(
                CGRect(x: 1960, y: 44, width: 1120, height: 678),
                displayOrigin: CGPoint(x: 1920, y: 0),
                displayPixelSize: CGSize(width: 2560, height: 1600)
            )
        )
    }

    func testMaximumSafeAreaWindowIsNotMistakenForFullscreen() {
        XCTAssertFalse(
            CaptureSession.isFullVirtualDisplayFrame(
                CGRect(x: 1960, y: 44, width: 1526, height: 916),
                displayOrigin: CGPoint(x: 1920, y: 0),
                displayPixelSize: CGSize(width: 1664, height: 1040)
            )
        )
    }

    func testBorderlessFullscreenWithTitleBarInsetIsDetected() {
        XCTAssertTrue(
            CaptureSession.isFullVirtualDisplayFrame(
                CGRect(x: 1920, y: 30, width: 1664, height: 1010),
                displayOrigin: CGPoint(x: 1920, y: 0),
                displayPixelSize: CGSize(width: 1664, height: 1040)
            )
        )
    }

    func testInteractionCannotEnterVirtualDisplayDockTriggerZone() {
        let display = CGRect(x: 2000, y: 1000, width: 1280, height: 800)

        XCTAssertTrue(
            CaptureSession.isOutsideDockTriggerZone(
                CGPoint(x: 2200, y: 1600),
                displayBounds: display
            )
        )
        XCTAssertFalse(
            CaptureSession.isOutsideDockTriggerZone(
                CGPoint(x: 2200, y: 1750),
                displayBounds: display
            )
        )
    }

    func testOversizedCapturedContentCanUseVisibleControlsInsideDockStrip() {
        let display = CGRect(x: 2000, y: 1000, width: 1280, height: 800)
        let captured = CGRect(x: 2046, y: 1050, width: 1188, height: 750)

        XCTAssertTrue(
            CaptureSession.canForwardInteraction(
                at: CGPoint(x: 3200, y: 1760),
                displayBounds: display,
                capturedContentFrame: captured
            )
        )
    }

    func testOrdinaryWindowStillCannotEnterDockTriggerZone() {
        let display = CGRect(x: 2000, y: 1000, width: 1280, height: 800)
        let captured = CGRect(x: 2046, y: 1050, width: 1000, height: 650)

        XCTAssertFalse(
            CaptureSession.canForwardInteraction(
                at: CGPoint(x: 3000, y: 1760),
                displayBounds: display,
                capturedContentFrame: captured
            )
        )
    }

    func testVirtualDisplaysUseTwoTimesBackingScale() {
        XCTAssertEqual(VirtualDisplayHost.backingScaleFactor, 2)
        XCTAssertEqual(VirtualDisplayHost.hiDPISetting, 1)
    }

    func testQuartzWindowFrameConvertsToAppKitSpaceOnDisplayBelowPrimary() {
        let appKitFrame = CoordinateTranslator.appKitFrame(
            fromQuartzFrame: CGRect(x: 1920, y: 1180, width: 1000, height: 700),
            primaryScreenHeight: 1080
        )

        XCTAssertEqual(appKitFrame, CGRect(x: 1920, y: -800, width: 1000, height: 700))
    }

    func testQuartzWindowFrameConvertsToAppKitSpaceOnDisplayAbovePrimary() {
        let appKitFrame = CoordinateTranslator.appKitFrame(
            fromQuartzFrame: CGRect(x: 0, y: -700, width: 1000, height: 600),
            primaryScreenHeight: 1080
        )

        XCTAssertEqual(appKitFrame, CGRect(x: 0, y: 1180, width: 1000, height: 600))
    }

    func testVirtualDisplayPixelSizeConvertsToWindowCoordinateSize() {
        let coordinateSize = VirtualDisplayHost.coordinateSize(
            pixelSize: CGSize(width: 2560, height: 1600),
            pointsPerPixel: CGSize(width: 0.5, height: 0.5)
        )

        XCTAssertEqual(coordinateSize.width, 1280, accuracy: 0.001)
        XCTAssertEqual(coordinateSize.height, 800, accuracy: 0.001)
    }

    func testVirtualDisplayCoordinateScaleSurvivesLiveModeResize() {
        let coordinateScale = VirtualDisplayHost.coordinateScale(
            registeredSize: CGSize(width: 1280, height: 800),
            descriptorPixelSize: CGSize(width: 2560, height: 1600)
        )
        let coordinateSize = VirtualDisplayHost.coordinateSize(
            pixelSize: CGSize(width: 1408, height: 880),
            pointsPerPixel: coordinateScale
        )

        XCTAssertEqual(coordinateScale.width, 0.5, accuracy: 0.001)
        XCTAssertEqual(coordinateScale.height, 0.5, accuracy: 0.001)
        XCTAssertEqual(coordinateSize.width, 704, accuracy: 0.001)
        XCTAssertEqual(coordinateSize.height, 440, accuracy: 0.001)
    }

    func testCaptureOutputUsesRetinaBackingPixelsAtMaximumQuality() {
        let outputSize = CaptureSession.outputPixelSize(
            for: CGSize(width: 1176, height: 614),
            pixelsPerPoint: CGSize(width: 2, height: 2),
            maxLongEdge: 2560
        )

        XCTAssertEqual(outputSize.width, 2352, accuracy: 0.001)
        XCTAssertEqual(outputSize.height, 1228, accuracy: 0.001)
    }

    func testCaptureOutputCapsRetinaPixelsAtSelectedQuality() {
        let outputSize = CaptureSession.outputPixelSize(
            for: CGSize(width: 1176, height: 614),
            pixelsPerPoint: CGSize(width: 2, height: 2),
            maxLongEdge: 1280
        )

        XCTAssertEqual(outputSize.width, 1280, accuracy: 0.001)
        XCTAssertEqual(outputSize.height, 668, accuracy: 0.001)
    }

    func testCenterClickMapsToWindowCenter() {
        let viewBounds = CGRect(x: 0, y: 0, width: 340, height: 340)
        let nativeSize = CGSize(width: 500, height: 400)
        let displayedRect = CGRect(x: 0, y: 20, width: 340, height: 272) // resizeAspect letterbox
        let windowFrame = CGRect(x: 100, y: 50, width: 500, height: 400)

        let point = CoordinateTranslator.globalPoint(
            forLocalPoint: CGPoint(x: 170, y: 156),
            viewBounds: viewBounds,
            nativeSize: nativeSize,
            displayedVideoRect: displayedRect,
            windowGlobalFrame: windowFrame
        )

        XCTAssertNotNil(point)
        XCTAssertEqual(point!.x, 350, accuracy: 2)
        XCTAssertEqual(point!.y, 250, accuracy: 2)
    }

    func testTopLeftClickMapsToWindowTopLeft() {
        let viewBounds = CGRect(x: 0, y: 0, width: 340, height: 340)
        let nativeSize = CGSize(width: 500, height: 400)
        let displayedRect = CGRect(x: 0, y: 20, width: 340, height: 272)
        let windowFrame = CGRect(x: 100, y: 50, width: 500, height: 400)

        // Local point just inside the top-left corner of the displayed video rect (AppKit
        // space: high Y is visually the top of the view). CGRect.contains treats maxX/maxY as
        // exclusive, so use a point just inside the edge rather than exactly on it.
        let point = CoordinateTranslator.globalPoint(
            forLocalPoint: CGPoint(x: 0.1, y: 291.9),
            viewBounds: viewBounds,
            nativeSize: nativeSize,
            displayedVideoRect: displayedRect,
            windowGlobalFrame: windowFrame
        )

        XCTAssertNotNil(point)
        XCTAssertEqual(point!.x, 100, accuracy: 2)
        XCTAssertEqual(point!.y, 50, accuracy: 2)
    }

    func testClickInLetterboxBarReturnsNil() {
        let viewBounds = CGRect(x: 0, y: 0, width: 340, height: 340)
        let nativeSize = CGSize(width: 500, height: 400)
        let displayedRect = CGRect(x: 0, y: 20, width: 340, height: 272)
        let windowFrame = CGRect(x: 100, y: 50, width: 500, height: 400)

        let point = CoordinateTranslator.globalPoint(
            forLocalPoint: CGPoint(x: 10, y: 5), // below the letterboxed video content
            viewBounds: viewBounds,
            nativeSize: nativeSize,
            displayedVideoRect: displayedRect,
            windowGlobalFrame: windowFrame
        )

        XCTAssertNil(point)
    }

    func testCaptureSourceRectMatchesVisibleIntersectionForOversizedWindow() {
        let sourceRect = CaptureSession.captureSourceRect(
            for: CGRect(x: 40, y: 44, width: 1200, height: 900),
            displaySize: CGSize(width: 1280, height: 800)
        )

        // The ordinary 6pt edge inset is applied first, then the portion extending below the
        // virtual display is clipped away.
        XCTAssertEqual(sourceRect, CGRect(x: 46, y: 50, width: 1188, height: 750))
    }

    func testCapturedContentGlobalFrameUsesClippedDisplayRegion() {
        let frame = CaptureSession.globalCaptureFrame(
            localRect: CGRect(x: 40, y: 44, width: 1200, height: 900),
            displayOrigin: CGPoint(x: 2560, y: 0),
            displaySize: CGSize(width: 1280, height: 800)
        )

        XCTAssertEqual(frame, CGRect(x: 2606, y: 50, width: 1188, height: 750))
    }

    func testBottomHalfClickUsesCapturedHeightInsteadOfOversizedAXHeight() {
        let capturedFrame = CGRect(x: 2606, y: 50, width: 1188, height: 750)
        let point = CoordinateTranslator.globalPoint(
            forLocalPoint: CGPoint(x: 200, y: 0.1),
            viewBounds: CGRect(x: 0, y: 0, width: 400, height: 300),
            // Simulates the stale full AX size that previously drove Bilibili/RedNote mapping.
            nativeSize: CGSize(width: 1200, height: 900),
            displayedVideoRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            windowGlobalFrame: capturedFrame
        )

        XCTAssertNotNil(point)
        XCTAssertEqual(point!.x, capturedFrame.midX, accuracy: 0.01)
        XCTAssertEqual(point!.y, capturedFrame.maxY - 0.25, accuracy: 0.01)
        XCTAssertLessThan(point!.y, 800.01)
    }
}

final class FlingCandidateMatcherTests: XCTestCase {
    func testUniqueBilibiliTitleWinsWhenScreenCaptureFrameIsStale() {
        let candidates = [
            FlingCandidateSnapshot(
                title: "哔哩哔哩 (゜-゜)つロ 干杯~-bilibili",
                frame: CGRect(x: 100, y: 100, width: 1000, height: 700)
            ),
            FlingCandidateSnapshot(
                title: "设置",
                frame: CGRect(x: 300, y: 200, width: 500, height: 500)
            ),
        ]

        let index = FlingCandidateMatcher.matchingIndex(
            candidates: candidates,
            axTitle: "哔哩哔哩",
            liveFrame: CGRect(x: 2500, y: 120, width: 1000, height: 700)
        )

        XCTAssertEqual(index, 0)
    }

    func testSingleElectronWindowMatchesDespiteStaleFrameAndMissingTitle() {
        let candidates = [
            FlingCandidateSnapshot(
                title: "Video",
                frame: CGRect(x: 100, y: 100, width: 1000, height: 700)
            ),
        ]

        let index = FlingCandidateMatcher.matchingIndex(
            candidates: candidates,
            axTitle: nil,
            liveFrame: CGRect(x: 2400, y: 100, width: 1000, height: 700)
        )

        XCTAssertEqual(index, 0)
    }

    func testAmbiguousStaleWindowsAreRejected() {
        let candidates = [
            FlingCandidateSnapshot(title: "Window A", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            FlingCandidateSnapshot(title: "Window B", frame: CGRect(x: 900, y: 0, width: 800, height: 600)),
        ]

        let index = FlingCandidateMatcher.matchingIndex(
            candidates: candidates,
            axTitle: nil,
            liveFrame: CGRect(x: 3000, y: 0, width: 800, height: 600)
        )

        XCTAssertNil(index)
    }
}

final class WindowCandidateTitleTests: XCTestCase {
    func testVisibleTitlelessWordStartWindowUsesAccessibilityTitle() {
        XCTAssertEqual(
            WindowEnumerator.candidateTitle(
                windowTitle: nil,
                ownerBundleIdentifier: "com.microsoft.Word",
                titlelessAccessibilityFallback: "打开新的和最近使用的文件"
            ),
            "打开新的和最近使用的文件"
        )
    }

    func testWhitespaceOnlyWordStartWindowUsesAccessibilityTitle() {
        XCTAssertEqual(
            WindowEnumerator.candidateTitle(
                windowTitle: "  \n",
                ownerBundleIdentifier: "com.microsoft.Word",
                titlelessAccessibilityFallback: "Open New or Recent"
            ),
            "Open New or Recent"
        )
    }

    func testTitlelessWordWindowWithoutMatchingAccessibilityWindowRemainsExcluded() {
        XCTAssertNil(
            WindowEnumerator.candidateTitle(
                windowTitle: nil,
                ownerBundleIdentifier: "com.microsoft.Word",
                titlelessAccessibilityFallback: nil
            )
        )
    }

    func testOtherTitlelessVisibleWindowRemainsExcluded() {
        XCTAssertNil(
            WindowEnumerator.candidateTitle(
                windowTitle: nil,
                ownerBundleIdentifier: "com.example.app",
                titlelessAccessibilityFallback: "Example Window"
            )
        )
    }

    func testRealDocumentTitleIsPreserved() {
        XCTAssertEqual(
            WindowEnumerator.candidateTitle(
                windowTitle: "Document 1",
                ownerBundleIdentifier: "com.microsoft.Word",
                titlelessAccessibilityFallback: nil
            ),
            "Document 1"
        )
    }
}

final class VideoPlaybackDetectionTests: XCTestCase {
    func testBrowserMediaSessionMatchesOnlyItsTitledWindow() {
        var info = NowPlayingInfo()
        info.bundleIdentifier = "company.thebrowser.Browser"
        info.title = "PiPanel 使用演示"
        info.playing = true

        XCTAssertTrue(WindowEnumerator.videoPlaybackMatches(
            info,
            sourceBundleIdentifier: "company.thebrowser.Browser",
            windowTitle: "PiPanel 使用演示 - 哔哩哔哩"
        ))
        XCTAssertFalse(WindowEnumerator.videoPlaybackMatches(
            info,
            sourceBundleIdentifier: "company.thebrowser.Browser",
            windowTitle: "GitHub - PiPanel"
        ))
    }

    func testNativeBilibiliMediaSessionDoesNotRequireTitleMatch() {
        var info = NowPlayingInfo()
        info.bundleIdentifier = "com.bilibili.bilibiliPC"
        info.title = "正在播放的视频"
        info.playing = false

        XCTAssertTrue(WindowEnumerator.videoPlaybackMatches(
            info,
            sourceBundleIdentifier: "com.bilibili.bilibiliPC",
            windowTitle: "哔哩哔哩"
        ))
    }

    func testMediaSessionFromAnotherAppNeverMatches() {
        var info = NowPlayingInfo()
        info.bundleIdentifier = "com.apple.Music"
        info.title = "PiPanel 使用演示"

        XCTAssertFalse(WindowEnumerator.videoPlaybackMatches(
            info,
            sourceBundleIdentifier: "com.apple.Safari",
            windowTitle: "PiPanel 使用演示"
        ))
    }
}

final class VirtualDisplayPlacementTests: XCTestCase {
    private let mainDisplayID: CGDirectDisplayID = 1

    func testRegisteredVirtualDisplayFillsLaggingNSScreenSnapshot() {
        let observed: [CGDirectDisplayID: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        ]
        let registeredVirtual: [CGDirectDisplayID: CGRect] = [
            819: CGRect(x: 1920, y: 0, width: 1920, height: 1200),
        ]

        let merged = VirtualDisplayHost.mergedActiveDisplayFrames(
            observed: observed,
            registeredVirtual: registeredVirtual,
            excluding: kCGNullDirectDisplay
        )

        XCTAssertEqual(merged[819], registeredVirtual[819])
        XCTAssertEqual(merged.values.map(\.maxX).max(), 3840)
    }

    func testRegisteredVirtualDisplayReplacesStaleObservedFrame() {
        let observed: [CGDirectDisplayID: CGRect] = [
            819: CGRect(x: 1920, y: 0, width: 1280, height: 800),
        ]
        let registeredVirtual: [CGDirectDisplayID: CGRect] = [
            819: CGRect(x: 3200, y: 0, width: 1280, height: 800),
        ]

        let merged = VirtualDisplayHost.mergedActiveDisplayFrames(
            observed: observed,
            registeredVirtual: registeredVirtual,
            excluding: kCGNullDirectDisplay
        )

        XCTAssertEqual(merged[819]?.origin.x, 3200)
    }

    func testHorizontalPhysicalLayoutContinuesToTheRight() {
        let physical: [CGDirectDisplayID: CGRect] = [
            mainDisplayID: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            2: CGRect(x: 1920, y: 0, width: 2560, height: 1440),
        ]

        XCTAssertEqual(
            VirtualDisplayHost.preferredPlacementEdge(
                physicalFrames: physical,
                mainDisplayID: mainDisplayID
            ),
            .right
        )
        XCTAssertEqual(
            VirtualDisplayHost.placementOrigin(
                physicalFrames: physical,
                managedFrames: [:],
                mainDisplayID: mainDisplayID,
                newDisplaySize: CGSize(width: 1280, height: 800)
            ),
            CGPoint(x: 4480, y: 0)
        )
    }

    func testVerticallyStackedPhysicalDisplaysContinueBelow() {
        let physical: [CGDirectDisplayID: CGRect] = [
            mainDisplayID: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            2: CGRect(x: 120, y: 1080, width: 1920, height: 1200),
        ]

        XCTAssertEqual(
            VirtualDisplayHost.preferredPlacementEdge(
                physicalFrames: physical,
                mainDisplayID: mainDisplayID
            ),
            .below
        )
        XCTAssertEqual(
            VirtualDisplayHost.placementOrigin(
                physicalFrames: physical,
                managedFrames: [:],
                mainDisplayID: mainDisplayID,
                newDisplaySize: CGSize(width: 1280, height: 800)
            ),
            CGPoint(x: 0, y: 2280)
        )
    }

    func testVerticallyStackedPhysicalDisplaysContinueAbove() {
        let physical: [CGDirectDisplayID: CGRect] = [
            mainDisplayID: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            2: CGRect(x: 120, y: -1200, width: 1920, height: 1200),
        ]

        XCTAssertEqual(
            VirtualDisplayHost.preferredPlacementEdge(
                physicalFrames: physical,
                mainDisplayID: mainDisplayID
            ),
            .above
        )
        XCTAssertEqual(
            VirtualDisplayHost.placementOrigin(
                physicalFrames: physical,
                managedFrames: [:],
                mainDisplayID: mainDisplayID,
                newDisplaySize: CGSize(width: 1280, height: 800)
            ),
            CGPoint(x: 0, y: -2000)
        )
    }

    func testSecondVirtualDisplayKeepsFirstVirtualsVerticalAlignmentAfterPhysicalRebase() {
        let physical: [CGDirectDisplayID: CGRect] = [
            mainDisplayID: CGRect(x: 640, y: 0, width: 1920, height: 1080),
            2: CGRect(x: 640, y: 1080, width: 1920, height: 1200),
        ]
        let firstVirtual = CGRect(x: 0, y: 2280, width: 1280, height: 800)

        XCTAssertEqual(
            VirtualDisplayHost.placementOrigin(
                physicalFrames: physical,
                managedFrames: [819: firstVirtual],
                mainDisplayID: mainDisplayID,
                newDisplaySize: CGSize(width: 1280, height: 800)
            ),
            CGPoint(x: 0, y: 3080)
        )
    }

    func testPhysicalDisplayOnTheLeftContinuesToTheLeft() {
        let physical: [CGDirectDisplayID: CGRect] = [
            mainDisplayID: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            2: CGRect(x: -2560, y: 0, width: 2560, height: 1440),
        ]

        XCTAssertEqual(
            VirtualDisplayHost.placementOrigin(
                physicalFrames: physical,
                managedFrames: [:],
                mainDisplayID: mainDisplayID,
                newDisplaySize: CGSize(width: 1280, height: 800)
            ),
            CGPoint(x: -3840, y: 0)
        )
    }

    func testDisplayArrangementUsesRegisteredHiDPITopologySize() {
        XCTAssertEqual(
            VirtualDisplayHost.topologySize(
                registeredBounds: CGRect(x: 0, y: 0, width: 2560, height: 1600),
                logicalSize: CGSize(width: 1280, height: 800)
            ),
            CGSize(width: 2560, height: 1600)
        )
    }

    func testSecondRawHiDPIDisplayDoesNotOverlapFirstWhenStackedVertically() {
        let physical: [CGDirectDisplayID: CGRect] = [
            mainDisplayID: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            2: CGRect(x: 0, y: 1080, width: 1920, height: 1200),
        ]
        let firstVirtual = CGRect(x: 0, y: 2280, width: 2560, height: 1600)

        XCTAssertEqual(
            VirtualDisplayHost.placementOrigin(
                physicalFrames: physical,
                managedFrames: [819: firstVirtual],
                mainDisplayID: mainDisplayID,
                newDisplaySize: CGSize(width: 2560, height: 1600)
            ),
            CGPoint(x: 0, y: 3880)
        )
    }
}
