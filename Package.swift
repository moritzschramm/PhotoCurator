// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PhotoCurator",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PhotoCurator", targets: ["PhotoCuratorApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "7.0.0"))
    ],
    targets: [
        .target(
            name: "PhotoCuratorCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/PhotoCuratorCore"
        ),
        .target(
            name: "PhotoCuratorUI",
            dependencies: [
                "PhotoCuratorCore",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/PhotoCuratorUI"
        ),
        .executableTarget(
            name: "PhotoCuratorApp",
            dependencies: [
                "PhotoCuratorCore",
                "PhotoCuratorUI"
            ],
            path: "Sources/PhotoCuratorApp"
        ),
        .testTarget(
            name: "PhotoCuratorCoreTests",
            dependencies: [
                "PhotoCuratorCore",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Tests/PhotoCuratorCoreTests"
        )
    ]
)
