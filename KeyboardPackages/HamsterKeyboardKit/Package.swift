// swift-tools-version: 5.8
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "HamsterKeyboardKit",
  defaultLocalization: "zh-Hans",
  platforms: [
    .iOS(.v15),
  ],
  products: [
    .library(name: "HamsterKeyboardKit", targets: ["HamsterKeyboardKit"]),
  ],
  dependencies: [
    .package(path: "../HamsterKit"),
    .package(path: "../HamsterUIKit"),
    .package(path: "../RimeKit"),
    // .package(url: "https://github.com/michaeleisel/ZippyJSON.git", exact: "1.2.10"),
    .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.16"),
    .package(url: "https://github.com/jpsim/Yams.git", exact: "5.0.6"),
  ],
  targets: [
    .binaryTarget(
      name: "librime",
      path: "../../Frameworks/librime.xcframework"),
    .binaryTarget(
      name: "libleveldb",
      path: "../../Frameworks/libleveldb.xcframework"),
    .binaryTarget(
      name: "libmarisa",
      path: "../../Frameworks/libmarisa.xcframework"),
    .binaryTarget(
      name: "libopencc",
      path: "../../Frameworks/libopencc.xcframework"),
    .binaryTarget(
      name: "libyaml-cpp",
      path: "../../Frameworks/libyaml-cpp.xcframework"),
    .target(
      name: "HamsterKeyboardKit",
      dependencies: [
        "HamsterKit",
        "HamsterUIKit",
        // "ZippyJSON",
        "RimeKit",
      ],
      path: "Sources",
      resources: [.process("Resources")]),
    .testTarget(
      name: "HamsterKeyboardKitTests",
      dependencies: [
        "HamsterKeyboardKit",
        "Yams",
        "HamsterKit",
        "HamsterUIKit",
        "ZIPFoundation",
        // "ZippyJSON",
        "RimeKit",
        "librime",
        "libleveldb",
        "libmarisa",
        "libopencc",
        "libyaml-cpp",
      ],
      path: "Tests"),
  ])
