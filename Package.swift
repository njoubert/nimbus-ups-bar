// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NimbusUpsBar",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "NimbusUpsBar", targets: ["NimbusUpsBar"]),
    ],
    dependencies: [
        // Ours, MIT, no dependencies of its own: the GitHub-release auto-updater. Pinned by
        // Package.resolved; a new tag reaches this app only when someone bumps it here.
        .package(url: "https://github.com/njoubert/nimbus-updater.git", from: "1.4.0"),
    ],
    targets: [
        // The outage state machine and everything it needs, with no AppKit and no IOKit: the
        // readings, the policy, the phases, the simulated outage. Everything that decides
        // *what* to do lives here so it can be driven by fakes in the tests.
        .target(name: "UpsGuardCore"),
        .testTarget(name: "UpsGuardCoreTests", dependencies: ["UpsGuardCore"]),
        // The platform layer the app is built on, as a library so its logic is testable: the
        // IOKit power sources, the UPS over HID (fetch and decode, separately), Disk
        // Arbitration, who holds a volume, the health rules, the IOKit+HID merge. The decode,
        // the health rules and the volume filter run in CI against fixtures, no UPS needed.
        .target(
            name: "NimbusUpsBarKit",
            dependencies: ["UpsGuardCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("DiskArbitration"),
            ]
        ),
        .testTarget(name: "NimbusUpsBarKitTests", dependencies: ["NimbusUpsBarKit"], resources: [.copy("Fixtures")]),
        // The menu bar app: the monitor, the menu, the chart, the settings, the launchd
        // agent. build.sh wraps the binary into Nimbus UPS Bar.app.
        .executableTarget(
            name: "NimbusUpsBar",
            dependencies: [
                "UpsGuardCore",
                "NimbusUpsBarKit",
                .product(name: "NimbusUpdater", package: "nimbus-updater"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("DiskArbitration"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
    ]
)
