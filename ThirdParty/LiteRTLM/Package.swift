// swift-tools-version: 5.9
// Vendored local copy of github.com/google-ai-edge/LiteRT-LM (v0.13.x, Apache 2.0).
//
// Why vendored: Anu's Xcode project is generated, and Xcode refuses to link the
// upstream package's product into an app target because it declares an unsafe
// linker flag (`-Xlinker -all_load`), even when pinned by revision. A *local*
// package isn't subject to that rule, so we keep the Swift wrapper + the
// prebuilt binary target here and move `-all_load` to the AnuMac target's
// OTHER_LDFLAGS (see generate_xcodeproj.py). This is the same static-link setup
// the AI Edge Gallery Mac app uses. The heavy `.xcframework` still downloads
// from the upstream release via the binary targets below.
import PackageDescription

let package = Package(
  name: "LiteRTLM",
  platforms: [
    .iOS(.v15),
    .macOS(.v12),
  ],
  products: [
    .library(name: "LiteRTLM", targets: ["LiteRTLM"])
  ],
  targets: [
    .binaryTarget(
      name: "CLiteRTLM",
      url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.13.0/CLiteRTLM.xcframework.zip",
      checksum: "af23c77b8eae3f1888fc0348c133af8a13f1e8a89f5788de7e38457f512e768a"
    ),
    .binaryTarget(
      name: "CLiteRTLM_mac",
      url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.13.0/CLiteRTLM_mac.xcframework.zip",
      checksum: "5b5ca1d15763924247cc27931e2ab099f39fb06a12376df01d1f8f6242f1cec3"
    ),
    .target(
      name: "LiteRTLM",
      dependencies: [
        .target(name: "CLiteRTLM", condition: .when(platforms: [.iOS])),
        .target(name: "CLiteRTLM_mac", condition: .when(platforms: [.macOS])),
      ],
      path: "swift",
      exclude: [
        "CapabilitiesTests.swift",
        "EngineTests.swift",
        "ConversationTests.swift",
        "ToolTests.swift",
        "MessageTests.swift",
        "BUILD",
        "Info.plist",
      ]
      // NOTE: upstream sets linkerSettings `.unsafeFlags(["-Xlinker", "-all_load"])`
      // here. Removed so this product is consumable by the generated Xcode app
      // target; `-all_load` is applied on AnuMac instead.
    ),
  ]
)
