// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import NimbusUpsBarKit
import UpsGuardCore

/// `Holders.describe`: which processes count as apps the soft stage may ask to quit, and
/// which app a helper process belongs to. The paths are shapes, not files on this machine,
/// so the bundle id (which needs the bundle on disk) is not asserted.
final class HoldersTests: XCTestCase {

    func testMainProcessOfAnApp() {
        let h = Holders.describe(pid: 100, executable: "/Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app/Contents/MacOS/Adobe Lightroom Classic")
        XCTAssertTrue(h.isApp)
        XCTAssertEqual(h.appName, "Adobe Lightroom Classic")
        XCTAssertEqual(h.shortName, "Adobe Lightroom Classic")
    }

    func testHelperResolvesToTheOuterApp() {
        // A Chromium renderer: three .app bundles deep. The Quit menu belongs to the outermost.
        let h = Holders.describe(pid: 4242, executable: "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Versions/1/Helpers/Brave Browser Helper (Renderer).app/Contents/MacOS/Brave Browser Helper (Renderer)")
        XCTAssertTrue(h.isApp)
        XCTAssertEqual(h.appName, "Brave Browser")
    }

    func testDaemonIsNotAnApp() {
        let h = Holders.describe(pid: 200, executable: "/usr/sbin/smbd")
        XCTAssertFalse(h.isApp)
        XCTAssertNil(h.appName)
        XCTAssertNil(h.bundleID)
        XCTAssertEqual(h.shortName, "smbd")
        XCTAssertEqual(h.appKey, "200")
    }

    func testSystemAppsAreLeftAlone() {
        // Dock, Spotlight, Control Center, loginwindow: .app bundles under /System that nobody
        // quits. Before this they counted as apps and would have been sent a quit event.
        for exe in ["/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",
                    "/System/Library/CoreServices/Spotlight.app/Contents/MacOS/Spotlight",
                    "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
                    "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow",
                    "/System/Library/PrivateFrameworks/Foo.framework/XPCServices/foo.xpc/Contents/MacOS/foo"] {
            let h = Holders.describe(pid: 300, executable: exe)
            XCTAssertFalse(h.isApp, exe)
            XCTAssertNil(h.bundleID, exe)
        }
    }

    func testFinderIsAnAppButAlwaysKept() {
        // Finder lives under /System too, so it is not an app to the resolver; the policy's
        // always-kept list is the second line of defence for the holder that is one.
        let h = Holders.describe(pid: 300, executable: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder")
        XCTAssertFalse(h.isApp)
        let finder = Holder(pid: 300, executable: h.executable, appName: "Finder", bundleID: "com.apple.finder")
        XCTAssertTrue(Policy().isNeverQuit(finder))
    }

    func testUnreadablePathIsNotAnApp() {
        let h = Holders.describe(pid: 999_999, executable: "pid 999999")
        XCTAssertFalse(h.isApp)
        XCTAssertEqual(h.shortName, "pid 999999")
    }

    func testThisProcessIsDescribedThroughLaunchServices() {
        // The test runner is a real running process: NSRunningApplication fills in what the
        // path cannot, if LaunchServices knows it at all.
        let exe = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
        let h = Holders.describe(pid: getpid(), executable: exe)
        XCTAssertEqual(h.pid, getpid())
        XCTAssertEqual(h.executable, exe)
    }
}
