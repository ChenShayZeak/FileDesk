// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FileDesk",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "FileDesk", targets: ["FileDesk"])],
    targets: [
        .executableTarget(name: "FileDesk"),
        .testTarget(name: "FileDeskTests", dependencies: ["FileDesk"])
    ]
)
