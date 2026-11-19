import CommonCrypto
import CryptoKit
import Foundation
import Security
import UniformTypeIdentifiers

enum CipherMode: Equatable, Sendable {
    case encrypt
    case decrypt

    static let contentType = UTType(exportedAs: "local.filedesk.encrypted", conformingTo: .data)
    static let fileExtension = "filedesk"

    var title: String {
        switch self {
        case .encrypt: "加密文件"
        case .decrypt: "解密文件"
        }
    }
}

enum FileCipherError: LocalizedError {
    case invalidFormat
    case authenticationFailed
    case changedSource
    case keyGenerationFailed
    case unsupportedItem
    case createOutputFailed

    var errorDescription: String? {
        switch self {
        case .invalidFormat: "加密文件的格式不受支持，或文件不完整。"
        case .authenticationFailed: "密码不正确，或加密文件已损坏。"
        case .changedSource: "处理期间源文件的大小发生了变化。请关闭正在编辑它的应用后再试。"
        case .keyGenerationFailed: "无法生成加密密钥。"
        case .unsupportedItem: "请选择普通文件。文件夹、应用程序包和符号链接无法加密或解密。"
        case .createOutputFailed: "无法创建输出文件。"
        }
    }
}

enum FileCipher {
    // Version 1 stores a header followed by 1 MiB AES-GCM records, each with a 16-byte
    // tag. The header contains the version, a per-file salt and the plaintext length.
    // A record's nonce is its index padded to 12 bytes. The header and index are authenticated.
    private static let magic = Data([0x46, 0x44, 0x45, 0x53, 0x4b, 0x01])
    private static let saltLength = 16
    private static let chunkLength = 1_048_576
    private static let tagLength = 16

    static func requireRegularFile(_ file: URL) throws {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.isPackage != true else {
            throw FileCipherError.unsupportedItem
        }
    }

    static func digest(_ file: URL) throws -> SHA256.Digest {
        let freshURL = URL(fileURLWithPath: file.path, isDirectory: false)
        try FileCipher.requireRegularFile(freshURL)
        let handle = try FileHandle(forReadingFrom: freshURL)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize()
    }

    private struct CipherContext {
        let header: Data
        let key: SymmetricKey
    }

    @discardableResult
    static func transform(
        _ mode: CipherMode, source: URL, output: URL, password: String
    ) throws -> SHA256.Digest {
        try transform(
            source: source, output: output,
            inputPassword: mode == .decrypt ? password : nil,
            outputPassword: mode == .encrypt ? password : nil
        )
    }

    static func changePassword(source: URL, output: URL, oldPassword: String, newPassword: String) throws {
        _ = try transform(source: source, output: output, inputPassword: oldPassword, outputPassword: newPassword)
    }

    private static func transform(
        source: URL, output: URL, inputPassword: String?, outputPassword: String?
    ) throws -> SHA256.Digest {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let inputLength = try input.seekToEnd()
        try input.seek(toOffset: 0)

        let plaintextLength: UInt64
        let inputCipher: CipherContext?
        if let inputPassword {
            let headerLength = magic.count + saltLength + 8
            guard inputLength >= UInt64(headerLength) else { throw FileCipherError.invalidFormat }
            let header = try readExactly(headerLength, from: input, onEOF: .invalidFormat)
            guard header.starts(with: magic) else { throw FileCipherError.invalidFormat }
            let salt = Data(header.dropFirst(magic.count).prefix(saltLength))
            plaintextLength = header.suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let payloadLength = inputLength - UInt64(headerLength)
            let recordCount = plaintextLength == 0 ? 1 : (plaintextLength - 1) / UInt64(chunkLength) + 1
            guard payloadLength >= plaintextLength,
                  payloadLength - plaintextLength == recordCount * UInt64(tagLength) else {
                throw FileCipherError.invalidFormat
            }
            inputCipher = CipherContext(header: header, key: try deriveKey(password: inputPassword, salt: salt))
        } else {
            plaintextLength = inputLength
            inputCipher = nil
        }

        let outputCipher: CipherContext?
        if let outputPassword {
            let salt = try makeSalt()
            let header = magic + salt + encode(plaintextLength)
            outputCipher = CipherContext(header: header, key: try deriveKey(password: outputPassword, salt: salt))
        } else {
            outputCipher = nil
        }

        guard FileManager.default.createFile(
            atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]
        ) else { throw FileCipherError.createOutputFailed }

        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        if let outputCipher { try writer.write(contentsOf: outputCipher.header) }

        var bytesRemaining = plaintextLength
        var index: UInt64 = 0
        var plaintextHash = SHA256()
        repeat {
            let count = Int(min(bytesRemaining, UInt64(chunkLength)))
            let counter = encode(index)
            let nonce = try AES.GCM.Nonce(data: Data(repeating: 0, count: 4) + counter)

            let plaintext: Data
            if let inputCipher {
                let record = try readExactly(count + tagLength, from: input, onEOF: .invalidFormat)
                let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: record.prefix(count), tag: record.suffix(tagLength))
                do {
                    plaintext = try AES.GCM.open(box, using: inputCipher.key, authenticating: inputCipher.header + counter)
                } catch {
                    throw FileCipherError.authenticationFailed
                }
            } else {
                plaintext = try readExactly(count, from: input, onEOF: .changedSource)
            }
            plaintextHash.update(data: plaintext)

            if let outputCipher {
                let record = try AES.GCM.seal(
                    plaintext, using: outputCipher.key, nonce: nonce,
                    authenticating: outputCipher.header + counter
                )
                try writer.write(contentsOf: record.ciphertext)
                try writer.write(contentsOf: record.tag)
            } else {
                try writer.write(contentsOf: plaintext)
            }

            bytesRemaining -= UInt64(count)
            index += 1
        } while bytesRemaining > 0

        if let trailingByte = try input.read(upToCount: 1), !trailingByte.isEmpty {
            throw inputCipher == nil ? FileCipherError.changedSource : FileCipherError.invalidFormat
        }
        try writer.synchronize()
        try writer.close()
        return plaintextHash.finalize()
    }

    private static func encode(_ value: UInt64) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    private static func makeSalt() throws -> Data {
        var salt = Data(count: saltLength)
        let status = salt.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard status == errSecSuccess else { throw FileCipherError.keyGenerationFailed }
        return salt
    }

    private static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        let passwordBytes = password.precomposedStringWithCanonicalMapping.utf8CString
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            salt.withUnsafeBytes { (saltBuffer: UnsafeRawBufferPointer) in
                passwordBytes.withUnsafeBufferPointer { passwordBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuffer.baseAddress, passwordBuffer.count - 1,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress, saltBuffer.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000,
                        output.bindMemory(to: UInt8.self).baseAddress, output.count
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw FileCipherError.keyGenerationFailed }
        return SymmetricKey(data: key)
    }

    private static func readExactly(_ count: Int, from handle: FileHandle, onEOF: FileCipherError) throws -> Data {
        var bytes = Data()
        bytes.reserveCapacity(count)
        while bytes.count < count {
            guard let part = try handle.read(upToCount: count - bytes.count), !part.isEmpty else {
                throw onEOF
            }
            bytes.append(part)
        }
        return bytes
    }
}
