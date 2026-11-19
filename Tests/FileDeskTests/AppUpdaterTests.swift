import Foundation
import XCTest
@testable import FileDesk

final class AppUpdaterTests: XCTestCase {
    func testLatestStableTagUsesNumericOrderAndIgnoresUnrelatedRefs() {
        let hash = String(repeating: "a", count: 40)
        let refs = ["refs/tags/v1.9.9", "refs/tags/1.10.0", "refs/tags/v2.0.0-beta.1", "refs/tags/preview",
                    "refs/heads/v3.0.0", "refs/tags/v01.20.0", "refs/tags/1.10.0^{}"]
        let output = refs.reversed().map { hash + "\t" + $0 }.joined(separator: "\n")
        XCTAssertEqual(AppRelease.latest(in: output), AppRelease(tag: "1.10.0", objectID: hash))
        XCTAssertNil(AppRelease.latest(in: ""))
        XCTAssertNil(AppRelease.latest(in: "invalid\trefs/tags/v9.0.0"))
        XCTAssertEqual(AppRelease.latest(in: hash + "\trefs/tags/v0.3.1")?.version, "0.3.1")
    }
}
