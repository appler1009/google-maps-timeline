// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "LuxShared",
  platforms: [.macOS(.v13), .iOS(.v16)],
  products: [
    .library(name: "LuxShared", targets: ["LuxShared"])
  ],
  targets: [
    .target(name: "LuxShared", path: "Sources/LuxShared")
  ]
)
