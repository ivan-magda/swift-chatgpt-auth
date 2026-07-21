// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "swift-chatgpt-auth",
  platforms: [
    .iOS(.v16),
    .macOS(.v13),
    .tvOS(.v16),
    .watchOS(.v9),
    .visionOS(.v1),
  ],
  products: [
    .library(
      name: "ChatGPTAuth",
      targets: ["ChatGPTAuth"]
    )
  ],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.1.0")
  ],
  targets: [
    .target(
      name: "ChatGPTAuth"
    ),
    .testTarget(
      name: "ChatGPTAuthTests",
      dependencies: ["ChatGPTAuth"]
    ),
  ]
)
