import Foundation

enum NewFileFormat: String, CaseIterable, Sendable {
    case txt, md, rtf, csv, json, html

    var title: String {
        switch self {
        case .txt: String(localized: "纯文本（.txt）")
        case .md: "Markdown (.md)"
        case .rtf: String(localized: "富文本（.rtf）")
        case .csv: "CSV (.csv)"
        case .json: "JSON (.json)"
        case .html: "HTML (.html)"
        }
    }

    var initialContents: Data {
        let text: String
        switch self {
        case .txt, .md, .csv: text = ""
        case .rtf: text = #"{\rtf1\ansi }"#
        case .json: text = "{}\n"
        case .html: text = "<!doctype html>\n<html>\n<head><meta charset=\"utf-8\"><title></title></head>\n<body></body>\n</html>\n"
        }
        return Data(text.utf8)
    }
}
