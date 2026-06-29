// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftDKNI",
    platforms: [
        .iOS("15"),
        .macOS("11")
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "SwiftDKNI",
            targets: ["SwiftDKNI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/ifeLight/fitskit.git", branch: "master"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "SwiftDKNI",
            dependencies: [
                .product(name: "FITSKit", package: "fitskit")
            ],
        ),
        .testTarget(
            name: "SwiftDKNITests",
            dependencies: ["SwiftDKNI"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
