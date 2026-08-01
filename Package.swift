// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XPaste",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "XPasteCore", targets: ["XPasteCore"]),
        .executable(name: "XPaste", targets: ["XPaste"])
    ],
    targets: [
        .target(
            name: "XPasteCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "XPaste",
            dependencies: ["XPasteCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "XPasteCoreTests",
            dependencies: ["XPasteCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "XPasteAppTests",
            dependencies: ["XPaste"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
