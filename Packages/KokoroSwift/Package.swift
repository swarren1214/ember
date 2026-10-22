// swift-tools-version: 6.2
// Vendored copy of KokoroSwift 1.0.9 (https://github.com/mlalma/kokoro-ios, MIT).
// Changed for Hearken (copied into Sated unchanged): its config is copied as "KokoroData" instead of "Resources" (see the
// note in ../MisakiSwift/Package.swift), and it uses the vendored MisakiSwift.

// Also changed for Hearken: built as a static library (no "type: .dynamic"), so it links into
// the app itself. As a dynamic framework from a local package, Xcode didn't embed it in the
// app, and the app crashed at launch with "Library not loaded: @rpath/KokoroSwift.framework".

import PackageDescription

let package = Package(
  name: "KokoroSwift",
  platforms: [
    .iOS(.v18), .macOS(.v15)
  ],
  products: [
    .library(name: "KokoroSwift", targets: ["KokoroSwift"]),
  ],
  dependencies: [
    .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.29.1"),
    .package(path: "../MisakiSwift"),
    .package(url: "https://github.com/mlalma/MLXUtilsLibrary.git", from: "0.0.6")
  ],
  targets: [
    .target(
      name: "KokoroSwift",
      dependencies: [
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXNN", package: "mlx-swift"),
        .product(name: "MLXRandom", package: "mlx-swift"),
        .product(name: "MLXFFT", package: "mlx-swift"),
        .product(name: "MisakiSwift", package: "MisakiSwift"),
        .product(name: "MLXUtilsLibrary", package: "MLXUtilsLibrary")
      ],
      resources: [
        .copy("../../KokoroData")
      ]
    ),
  ]
)
