// swift-tools-version: 5.9
import PackageDescription

// Headless benchmark for the LiteRT-LM runtime AnuMac uses — measures the real
// prefill + decode tok/s of Gemma 4 E4B on this Mac's GPU. Depends on the same
// vendored local package AnuMac links, so the number it prints is exactly what
// AnuMac (and Gallery, same engine) achieve.
let package = Package(
  name: "lrtbench",
  platforms: [.macOS(.v13)],
  dependencies: [
    .package(path: "../../ThirdParty/LiteRTLM")
  ],
  targets: [
    .executableTarget(
      name: "lrtbench",
      dependencies: [.product(name: "LiteRTLM", package: "LiteRTLM")],
      linkerSettings: [.unsafeFlags(["-Xlinker", "-all_load"])]  // force-load the static runtime
    )
  ]
)
