// swift-tools-version: 5.9
// NOTE: This package is NOT used to build the app.
// Open Anu.xcodeproj in Xcode to build and run the iOS app.
// This file exists only for tooling compatibility (e.g. Swift Package Index).
import PackageDescription

let package = Package(
    name: "Anu",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [],
    targets: []
)
