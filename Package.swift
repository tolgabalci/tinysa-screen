// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "TinySAScreen",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "tinysa-screen", targets: ["TinySAScreen"]),
    .library(name: "TinySAKit", targets: ["TinySAKit"]),
  ],
  targets: [
    // The tinySA side: finding it on USB, its console, its screen formats, and working alongside other programs.
    .target(name: "TinySAKit"),
    // The Mac app: the window, its menus, and the clicks sent to the analyzer as taps.
    .executableTarget(name: "TinySAScreen", dependencies: ["TinySAKit"]),
    .testTarget(name: "TinySAKitTests", dependencies: ["TinySAKit"], resources: [.copy("Fixtures")]),
  ]
)
