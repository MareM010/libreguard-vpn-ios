// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LibreGuardOpenSSL",
    platforms: [.iOS(.v15), .macOS(.v10_15)],
    products: [.library(name: "openssl-apple", targets: ["openssl", "OpenSSLPrivacy"])],
    targets: [
        .binaryTarget(name: "openssl", path: "openssl.xcframework"),
        .target(name: "OpenSSLPrivacy", path: "Privacy", resources: [.process("PrivacyInfo.xcprivacy")])
    ]
)
