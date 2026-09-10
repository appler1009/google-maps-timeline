// swift-tools-version:5.9
import PackageDescription

// Deliberately its own standalone package, not a product of the main LogDock manifest: a local
// Swift Package reference resolves the *entire* referenced manifest's dependency graph, even for
// products with no dependencies of their own — so if LogShip lived in the same Package.swift as
// LogDockCore (which depends on the MCP swift-sdk, which pulls in swift-nio), any app adding
// LogShip would also have to successfully resolve all of that just to get a small HTTP client.
let package = Package(
  name: "LogShip",
  platforms: [.macOS(.v13), .iOS(.v15)],
  products: [
    .library(name: "LogShip", targets: ["LogShip"])
  ],
  targets: [
    .target(name: "LogShip")
  ]
)
