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

final class SharedVirtualCanvasLayoutTests: XCTestCase {
    func testSharedWorkspacePreservesEdgeAndMenuBarMargins() {
        let workspace = SharedVirtualCanvasLayout.workspaceFrame(
            in: CGSize(width: 2560, height: 1600)
        )

        XCTAssertEqual(workspace, CGRect(x: 40, y: 44, width: 2480, height: 1516))
    }

    func testInvalidCanvasProducesNoWorkspace() {
        XCTAssertEqual(SharedVirtualCanvasLayout.workspaceFrame(in: .zero), .zero)
    }

    func testOversizedSourceIsScaledUniformlyIntoSlot() {
        XCTAssertEqual(
            SharedVirtualCanvasLayout.sizeFitting(
                CGSize(width: 3000, height: 2000),
                within: CGSize(width: 1200, height: 800)
            ),
            CGSize(width: 1200, height: 800)
        )
    }

    func testSmallSourceIsNotUpscaled() {
        XCTAssertEqual(
            SharedVirtualCanvasLayout.sizeFitting(
                CGSize(width: 800, height: 500),
                within: CGSize(width: 1200, height: 800)
            ),
            CGSize(width: 800, height: 500)
        )
    }

    func testSlotOwnershipUsesWindowCenter() {
        let slot = CGRect(x: 40, y: 44, width: 1280, height: 800)
        XCTAssertTrue(
            SharedVirtualCanvasLayout.ownsCenter(
                of: CGRect(x: 1200, y: 100, width: 200, height: 400),
                workspaceFrame: slot
            )
        )
        XCTAssertFalse(
            SharedVirtualCanvasLayout.ownsCenter(
                of: CGRect(x: 1320, y: 100, width: 800, height: 600),
                workspaceFrame: slot
            )
        )
    }
}

final class SharedVirtualCanvasLeaseAllocatorTests: XCTestCase {
    func testConcurrentLayersHaveUniqueIdentitiesWithoutFixedCapacity() {
        var allocator = SharedVirtualCanvasLeaseAllocator()
        let identities = (0..<12).map { _ in allocator.lease() }

        XCTAssertEqual(Set(identities).count, 12)
        XCTAssertEqual(allocator.activeIDs.count, 12)
    }

    func testReleasedIdentityIsReusedWithoutAffectingOtherLayers() {
        var allocator = SharedVirtualCanvasLeaseAllocator()
        let first = allocator.lease()
        let second = allocator.lease()
        allocator.release(first)

        XCTAssertEqual(allocator.lease(), first)
        XCTAssertTrue(allocator.activeIDs.contains(second))
        XCTAssertEqual(allocator.activeIDs.count, 2)
    }
}

final class CoordinateTranslatorTests: XCTestCase {
    func testDisplayRefreshRateUsesFastestCurrentDisplay() {
        XCTAssertEqual(DisplayRefreshRate.maximumFPS(from: [60, 120, 144]), 144)
    }

    func testDisplayRefreshRateFallsBackWhenSystemReportsNoRate() {
        XCTAssertEqual(DisplayRefreshRate.maximumFPS(from: [0, -1]), 60)
    }

    func testCaptureFrameRateIsLimitedBySourceDisplay() {
        XCTAssertEqual(CaptureSession.effectiveFrameRate(requested: 144, displayMaximum: 60), 60)
        XCTAssertEqual(CaptureSession.effectiveFrameRate(requested: 120, displayMaximum: 144), 120)
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
