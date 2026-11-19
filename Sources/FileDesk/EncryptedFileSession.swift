import CryptoKit
import Foundation
import UniformTypeIdentifiers

struct EncryptedFileSession: Identifiable, Sendable {
    let id: UUID
    let file: URL
    let text: String?

    var title: String { file.lastPathComponent }
}

enum EncryptedSessionError: LocalizedError {
    case alreadyOpen
    case originalChanged
    case copyChanged

    var errorDescription: String? {
        switch self {
        case .alreadyOpen: String(localized: "请先关闭当前解密会话。")
        case .originalChanged: String(localized: "原加密文件已被移动、删除或修改，无法安全写回。临时副本中的修改已保留。")
        case .copyChanged: String(localized: "临时副本仍在变化。请先在编辑应用中保存并关闭文件，再重试。")
        }
    }
}

actor EncryptedFileSessions {
    private struct OpenFile {
        let session: EncryptedFileSession
        let encryptedFile: URL
        let originalDigest: SHA256.Digest
        let plaintextDigest: SHA256.Digest
        let password: String
        let hasUTF8BOM: Bool
        var updated: Bool?
    }

    private let manager = FileManager()
    private var active: OpenFile?

    func open(_ encryptedFile: URL, password: String) throws -> EncryptedFileSession {
        guard active == nil else { throw EncryptedSessionError.alreadyOpen }
        let encryptedFile = try validateEncryptedFile(encryptedFile)
        let id = UUID()
        let name = encryptedFile.deletingPathExtension().lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { throw FileCipherError.invalidFormat }
        let folder = try privateDirectory(in: manager.temporaryDirectory, id: id)
        let file = folder.appendingPathComponent(name, isDirectory: false)

        do {
            let originalDigest = try FileCipher.digest(encryptedFile)
            let plaintextDigest = try FileCipher.transform(.decrypt, source: encryptedFile, output: file, password: password)
            // Reject a file that was replaced or modified during decryption.
            guard (try? FileCipher.digest(encryptedFile)) == originalDigest else {
                throw EncryptedSessionError.originalChanged
            }

            let editable = try editableText(at: file)
            let session = EncryptedFileSession(id: id, file: file, text: editable?.text)
            active = OpenFile(
                session: session, encryptedFile: encryptedFile,
                originalDigest: originalDigest, plaintextDigest: plaintextDigest,
                password: password, hasUTF8BOM: editable?.hasBOM == true
            )
            return session
        } catch {
            try? manager.removeItem(at: folder)
            throw error
        }
    }

    func changePassword(_ file: URL, oldPassword: String, newPassword: String) throws {
        guard active == nil else { throw EncryptedSessionError.alreadyOpen }
        let encrypted = try validateEncryptedFile(file)
        let originalDigest = try FileCipher.digest(encrypted)
        let staging = try privateDirectory(in: encrypted.deletingLastPathComponent(), id: UUID())
        defer { try? manager.removeItem(at: staging) }

        let replacement = staging.appendingPathComponent(encrypted.lastPathComponent)
        try FileCipher.changePassword(
            source: encrypted, output: replacement, oldPassword: oldPassword, newPassword: newPassword
        )
        try replaceEncryptedFile(encrypted, with: replacement, originalDigest: originalDigest)
    }

    func saveDraft(_ draft: String) throws {
        guard let active, active.updated == nil, active.session.text != nil else { return }
        var bytes = Data(draft.utf8)
        if active.hasUTF8BOM {
            bytes.insert(contentsOf: [0xef, 0xbb, 0xbf], at: bytes.startIndex)
        }
        try bytes.write(to: active.session.file, options: .atomic)
    }

    /// Returns whether the encrypted file changed. A failed writeback keeps the temporary file open.
    func close(draft: String?, discardingChanges: Bool = false) throws -> Bool {
        guard let active else { return false }
        if let draft, !discardingChanges {
            try saveDraft(draft)
        }

        let updated: Bool
        if let alreadyUpdated = active.updated {
            updated = alreadyUpdated
        } else if discardingChanges {
            updated = false
        } else {
            updated = try writeBackIfChanged(active)
        }

        // Record a successful writeback even if cleanup must be retried.
        self.active?.updated = updated
        do {
            try manager.removeItem(at: active.session.file.deletingLastPathComponent())
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // The directory was already removed.
        }
        self.active = nil
        return updated
    }

    private func writeBackIfChanged(_ openFile: OpenFile) throws -> Bool {
        let plaintext = openFile.session.file
        let encrypted = openFile.encryptedFile
        let changedDigest = try FileCipher.digest(plaintext)
        guard changedDigest != openFile.plaintextDigest else { return false }
        guard (try? FileCipher.digest(encrypted)) == openFile.originalDigest else {
            throw EncryptedSessionError.originalChanged
        }

        let staging = try privateDirectory(in: encrypted.deletingLastPathComponent(), id: UUID())
        defer { try? manager.removeItem(at: staging) }
        let replacement = staging.appendingPathComponent(encrypted.lastPathComponent)
        let stagedDigest = try FileCipher.transform(.encrypt, source: plaintext, output: replacement, password: openFile.password)
        guard stagedDigest == changedDigest else { throw EncryptedSessionError.copyChanged }

        try replaceEncryptedFile(
            encrypted, with: replacement, originalDigest: openFile.originalDigest,
            checking: (plaintext, changedDigest)
        )
        return true
    }

    private func replaceEncryptedFile(
        _ encrypted: URL, with replacement: URL, originalDigest: SHA256.Digest,
        checking plaintext: (file: URL, digest: SHA256.Digest)? = nil
    ) throws {
        // Coordinate the final content checks and replacement with macOS document writers.
        let coordinator = NSFileCoordinator()
        let manager = self.manager
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        func replace(_ target: URL) throws {
            guard (try? FileCipher.digest(target)) == originalDigest else {
                throw EncryptedSessionError.originalChanged
            }
            _ = try manager.replaceItemAt(target, withItemAt: replacement)
        }

        if let plaintext {
            coordinator.coordinate(
                readingItemAt: plaintext.file, options: [],
                writingItemAt: encrypted, options: .forReplacing,
                error: &coordinationError
            ) { coordinatedPlaintext, target in
                result = Result {
                    guard try FileCipher.digest(coordinatedPlaintext) == plaintext.digest else {
                        throw EncryptedSessionError.copyChanged
                    }
                    try replace(target)
                }
            }
        } else {
            coordinator.coordinate(writingItemAt: encrypted, options: .forReplacing, error: &coordinationError) { target in
                result = Result { try replace(target) }
            }
        }

        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        try result.get()
    }

    private func validateEncryptedFile(_ file: URL) throws -> URL {
        let file = URL(fileURLWithPath: file.path, isDirectory: false)
        guard file.pathExtension.lowercased() == CipherMode.fileExtension else {
            throw FileCipherError.invalidFormat
        }
        try FileCipher.requireRegularFile(file)
        return file
    }

    private func editableText(at file: URL) throws -> (text: String, hasBOM: Bool)? {
        let values = try file.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size <= 2_097_152,
              let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .text) else {
            return nil
        }

        let data = try Data(contentsOf: file)
        let hasBOM = data.starts(with: [0xef, 0xbb, 0xbf])
        guard let text = String(data: hasBOM ? Data(data.dropFirst(3)) : data, encoding: .utf8) else {
            return nil
        }
        return (text, hasBOM)
    }

    private func privateDirectory(in parent: URL, id: UUID) throws -> URL {
        let folder = parent.appendingPathComponent(".filedesk-" + id.uuidString, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return folder
    }
}
