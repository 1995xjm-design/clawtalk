// swift-tools-version: 5.8
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "RimeKit",
  platforms: [
    .iOS(.v15),
  ],
  products: [
    .library(name: "RimeKit", targets: ["RimeKit"]),
  ],
  dependencies: [
    .package(path: "../HamsterKit"),
  ],
  targets: [
    .binaryTarget(
      name: "librimeRIME",
      path: "../../Frameworks/librime.xcframework"),
    .binaryTarget(
      name: "libleveldbRIME",
      path: "../../Frameworks/libleveldb.xcframework"),
    .binaryTarget(
      name: "libmarisaRIME",
      path: "../../Frameworks/libmarisa.xcframework"),
    .binaryTarget(
      name: "libopenccRIME",
      path: "../../Frameworks/libopencc.xcframework"),
    .binaryTarget(
      name: "libyaml-cppRIME",
      path: "../../Frameworks/libyaml-cpp.xcframework"),
    .target(
      name: "RimeKitObjC",
      dependencies: [
        "librimeRIME",
        "libleveldbRIME",
        "libmarisaRIME",
        "libopenccRIME",
        "libyaml-cppRIME",
      ],
      path: "Sources/ObjC",
      linkerSettings: [
        .linkedLibrary("c++"),
      ]),
    .target(
      name: "RimeKit",
      dependencies: [
        "RimeKitObjC",
        "HamsterKit",
      ],
      path: "Sources/Swift"),
    .testTarget(
      name: "RimeKitTests",
      dependencies: [
        "RimeKit",
        "librimeRIME",
        "libleveldbRIME",
        "libmarisaRIME",
        "libopenccRIME",
        "libyaml-cppRIME",
      ]),
  ])
