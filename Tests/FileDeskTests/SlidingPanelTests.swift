import SwiftUI
import XCTest
@testable import FileDesk

final class SlidingPanelTests: XCTestCase {
    @MainActor
    func testPanelReservesIntermediateSpaceOnItsSlidingAxis() {
        for fraction: CGFloat in [0, 0.5, 1] {
            for axis in [Axis.horizontal, .vertical] {
                let panel = SlidingPanel(axis: axis, progress: fraction) {
                    Color.clear.frame(width: 200, height: 80)
                }
                let size = NSHostingView(rootView: panel).fittingSize
                XCTAssertEqual(size.width, axis == .horizontal ? 200 * fraction : 200, accuracy: 0.5)
                XCTAssertEqual(size.height, axis == .vertical ? 80 * fraction : 80, accuracy: 0.5)
            }
        }
    }
}
