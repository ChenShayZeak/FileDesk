import SwiftUI

enum AppLanguage: String {
    case system, chinese = "zh-Hans", english = "en"

    static func selection(in preferences: UserDefaults, domain: String) -> Self {
        guard let languages = preferences.persistentDomain(forName: domain)?["AppleLanguages"] as? [String],
              let first = languages.first else { return .system }
        switch Locale(identifier: first).language.languageCode?.identifier {
        case "zh": return .chinese
        case "en": return .english
        default: return .system
        }
    }

    func apply(to preferences: UserDefaults) {
        if self == .system {
            preferences.removeObject(forKey: "AppleLanguages")
        } else {
            preferences.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

enum BrowserTheme: String, CaseIterable {
    case violet, system, blue, green, orange, custom

    var title: LocalizedStringKey {
        switch self {
        case .violet: "紫色"
        case .system: "跟随系统"
        case .blue: "蓝色"
        case .green: "绿色"
        case .orange: "橙色"
        case .custom: "自定义"
        }
    }

    static func customData(for color: Color.Resolved) throws -> Data {
        try JSONEncoder().encode(SIMD3(color.linearRed, color.linearGreen, color.linearBlue))
    }

    func color(customData: Data) -> Color {
        switch self {
        case .violet: BrowserColors.violet
        case .system: Color(nsColor: .controlAccentColor)
        case .blue: .blue
        case .green: .green
        case .orange: .orange
        case .custom:
            if let rgb = try? JSONDecoder().decode(SIMD3<Float>.self, from: customData) {
                Color(.sRGBLinear, red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
            } else {
                BrowserColors.violet
            }
        }
    }
}

enum AppAppearance: String {
    case system, light, dark

    var nativeAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

private struct BrowserAccentKey: EnvironmentKey {
    static let defaultValue = BrowserColors.violet
}

extension EnvironmentValues {
    var browserAccent: Color {
        get { self[BrowserAccentKey.self] }
        set { self[BrowserAccentKey.self] = newValue }
    }
}

struct AppSettings: View {
    @Binding var theme: BrowserTheme
    @Binding var customColorData: Data
    @Binding var appearance: AppAppearance
    @Environment(\.self) private var environment
    @State private var language = AppLanguage.selection(in: .standard, domain: Bundle.main.bundleIdentifier ?? "")

    var body: some View {
        Form {
            Section {
                Picker("界面语言", selection: $language) {
                    Text("跟随系统").tag(AppLanguage.system)
                    Text(verbatim: "简体中文").tag(AppLanguage.chinese)
                    Text(verbatim: "English").tag(AppLanguage.english)
                }
                .onChange(of: language) { _, language in language.apply(to: .standard) }
            } footer: {
                Text("更改语言后，退出并重新打开文件桌即可生效。")
            }

            Section {
                Picker("外观模式", selection: $appearance) {
                    Text("跟随系统").tag(AppAppearance.system)
                    Text("白天模式").tag(AppAppearance.light)
                    Text("夜间模式").tag(AppAppearance.dark)
                }

                Picker("主题颜色", selection: $theme) {
                    ForEach(BrowserTheme.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                ColorPicker("自定义颜色", selection: Binding(
                    get: { BrowserTheme.custom.color(customData: customColorData) },
                    set: { color in
                        guard let data = try? BrowserTheme.customData(for: color.resolve(in: environment)) else { return }
                        customColorData = data
                        theme = .custom
                    }
                ), supportsOpacity: false)
            }
        }
        .formStyle(.grouped)
        .frame(width: 390)
        .fixedSize(horizontal: false, vertical: true)
    }
}
