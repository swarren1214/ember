// swift-tools-version: 6.2
// Vendored copy of MisakiSwift 1.0.4 (https://github.com/mlalma/MisakiSwift, Apache 2.0).
// Changed for Hearken (copied into Sated unchanged): the dictionaries are copied as "MisakiData" instead of "Resources".
// An iOS resource bundle with a top-level "Resources" folder looks like a macOS bundle to
// codesign, which then fails with "bundle format unrecognized, invalid, or unsuitable".

// Also changed for Hearken: built as a static library (no "type: .dynamic"), so it links into
// the app itself. As a dynamic framework from a local package, Xcode didn't embed it in the
// app, and the app crashed at launch with "Library not loaded: @rpath/MisakiSwift.framework".

import PackageDescription

let package = Package(
  name: "MisakiSwift",
  platforms: [
    .iOS(.v18), .macOS(.v15)
  ],
  products: [
    .library(name: "MisakiSwift", targets: ["MisakiSwift"]),
  ],
  dependencies: [
    .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.29.1"),
    .package(url: "https://github.com/mlalma/MLXUtilsLibrary.git", from: "0.0.6")
  ],
  targets: [
    .target(
      name: "MisakiSwift",
      dependencies: [
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXNN", package: "mlx-swift"),
        .product(name: "MLXUtilsLibrary", package: "MLXUtilsLibrary")
      ],
      resources: [
        .copy("../../MisakiData")
      ]
    ),
  ]
)
