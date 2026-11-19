import Foundation
import XCTest

final class LocalizationTests: XCTestCase {
    func testTranslationsCoverBothLanguagesAndFormatRuntimeValues() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts")
        let english = try XCTUnwrap(Bundle(url: resources.appendingPathComponent("en.lproj")))
        let chinese = try XCTUnwrap(Bundle(url: resources.appendingPathComponent("zh-Hans.lproj")))

        func keys(_ table: String, in bundle: Bundle) throws -> Set<String> {
            let url = try XCTUnwrap(bundle.url(forResource: table, withExtension: "strings"))
            let data = try Data(contentsOf: url)
            let values = try PropertyListSerialization.propertyList(from: data, format: nil)
            return Set(try XCTUnwrap(values as? [String: String]).keys)
        }

        for table in ["Localizable", "InfoPlist", "ServicesMenu"] {
            XCTAssertEqual(try keys(table, in: english), try keys(table, in: chinese), table)
        }

        let count = 12
        XCTAssertEqual(String(localized: "已复制 \(count) 条路径", bundle: english), "Paths copied: 12")
        XCTAssertEqual(String(localized: "已复制 \(count) 条路径", bundle: chinese), "已复制 12 条路径")
        let kind = "Folders"
        let app = "FileDesktop"
        XCTAssertEqual(String(localized: "\(kind)默认使用「\(app)」打开", bundle: english),
                       "Default app for Folders: FileDesktop")
    }
}
