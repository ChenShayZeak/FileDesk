import Foundation

struct RecentFile: Codable, Equatable {
    let path: String
    private let bookmark: Data?

    init(_ url: URL) {
        path = url.standardizedFileURL.path
        bookmark = try? url.bookmarkData(includingResourceValuesForKeys: [.fileResourceIdentifierKey])
    }

    static func load(from preferences: UserDefaults) -> [Self] {
        if let data = preferences.data(forKey: "recentFiles"),
           let stored = try? PropertyListDecoder().decode([Self].self, from: data) { return stored }
        let legacy = (preferences.stringArray(forKey: "recentFilePaths") ?? []).map {
            Self(URL(fileURLWithPath: $0, isDirectory: false))
        }
        if !legacy.isEmpty { save(legacy, to: preferences) }
        return legacy
    }

    static func save(_ files: [Self], to preferences: UserDefaults) {
        if let data = try? PropertyListEncoder().encode(files) {
            preferences.set(data, forKey: "recentFiles")
            preferences.removeObject(forKey: "recentFilePaths")
        }
    }

    private func isMissing(_ url: URL) -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return false
        } catch let error as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) {
            let parts = url.pathComponents
            if parts.count >= 3, parts[1] == "Volumes" {
                return FileManager.default.fileExists(atPath: "/Volumes/" + parts[2])
            }
            return true
        } catch {
            return false
        }
    }

    func resolved() -> Self? {
        let original = URL(fileURLWithPath: path, isDirectory: false)
        guard let bookmark else { return isMissing(original) ? nil : Self(original) }
        var stale = false
        guard var url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return isMissing(original) ? nil : self
        }

        // A bookmark may prefer the old path if a different file now occupies it.
        if stale, let id = URL.resourceValues(forKeys: [.fileResourceIdentifierKey], fromBookmarkData: bookmark)?.fileResourceIdentifier,
           let currentID = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
           !id.isEqual(currentID) {
            let siblings = try? FileManager.default.contentsOfDirectory(at: original.deletingLastPathComponent(),
                                                                        includingPropertiesForKeys: [.fileResourceIdentifierKey])
            if let renamed = siblings?.first(where: {
                let candidate = try? $0.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
                return id.isEqual(candidate)
            }) { url = renamed }
        }
        if isMissing(url) { return nil }
        guard stale || url.standardizedFileURL.path != path else { return self }
        var relationship = FileManager.URLRelationship.other
        try? FileManager.default.getRelationship(&relationship, of: .trashDirectory, in: .userDomainMask, toItemAt: url)
        return relationship == .contains ? nil : Self(url)
    }

    static func refresh(_ files: [Self]) async -> [Self] {
        uniquePaths(files.compactMap { $0.resolved() })
    }

    static func uniquePaths(_ files: [Self]) -> [Self] {
        var paths = Set<String>()
        return files.filter { paths.insert($0.path).inserted }
    }
}
