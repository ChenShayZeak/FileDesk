import SwiftUI
import XCTest
@testable import FileDesk

final class AppSettingsTests: XCTestCase {
    func testCustomAccentSurvivesSavingAndInvalidDataKeepsDefault() throws {
        let environment = EnvironmentValues()
        let chosen = Color(.displayP3, red: 0.23, green: 0.78, blue: 0.91).resolve(in: environment)
        let saved = try BrowserTheme.customData(for: chosen)
        XCTAssertEqual(BrowserTheme.custom.color(customData: saved).resolve(in: environment), chosen)
        XCTAssertEqual(BrowserTheme.custom.color(customData: Data()), BrowserColors.violet)
        XCTAssertEqual(BrowserTheme.blue.color(customData: saved), .blue)
    }
}
