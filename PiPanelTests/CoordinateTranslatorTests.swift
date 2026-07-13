import XCTest
@testable import PiPanel

final class CoordinateTranslatorTests: XCTestCase {
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
