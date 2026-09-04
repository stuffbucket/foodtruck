// swift-tools-version: 6.0
import PackageDescription

// FoodTruck has ZERO package dependencies, on purpose.
//
// It is the one thing a user is allowed to have before they have anything else,
// so it must build from a bare macOS with only Command Line Tools installed.
// Everything else -- task, brew, mise, node -- is unlocked by a recipe at
// runtime, never linked at build time.
let package = Package(
    name: "FoodTruck",
        // Deployment target 15, compiled against the macOS 26 SDK.
    //
    // Those are different levers and it matters which is which: standard
    // controls pick up the Liquid Glass restyle from the LINKED SDK, not the
    // deployment target, so building on 26 gets the current look while still
    // running on Sequoia. The ~dozen glass symbols themselves hard-error below
    // 26 and are gated explicitly in Surface.swift.
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FoodTruckKit", targets: ["FoodTruckKit"]),
        .executable(name: "foodtruck", targets: ["FoodTruck"]),
    ],
    targets: [
        .target(
            name: "FoodTruckKit",
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "FoodTruck",
            dependencies: ["FoodTruckKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
