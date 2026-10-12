// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import NimbusUpsBarKit
import UpsGuardCore

/// A made-up desk for `Holders`: which applications LaunchServices says are running, where
/// their bundles are, who started whom, and which of them were sent a quit.
final class FakeDesk {
    var apps: [RunningApp] = []
    var parents: [pid_t: pid_t] = [:]
    var terminated: [pid_t] = []
    var refuses: Set<pid_t> = []

    func run(_ pid: pid_t, _ bundlePath: String, _ bundleID: String, _ name: String, background: Bool = false) {
        apps.append(RunningApp(pid: pid, bundleID: bundleID, name: name, bundlePath: bundlePath, isBackgroundOnly: background) { [unowned self] in
            if refuses.contains(pid) { return false }
            terminated.append(pid)
            return true
        })
    }

    var world: ProcessWorld {
        ProcessWorld(application: { pid in self.apps.first { $0.pid == pid } },
                     applicationAt: { path in self.apps.first { $0.bundlePath == path } },
                     applications: { bid in self.apps.filter { $0.bundleID == bid } },
                     parent: { pid in self.parents[pid] })
    }
}

/// `Holders.describe`: which processes count as apps the soft stage may ask to quit and waits
/// for, and which app a helper process belongs to. The paths are shapes, not files on this
/// machine; what LaunchServices would say about them is the fake desk's.
final class HoldersTests: XCTestCase {
    var desk: FakeDesk!

    override func setUp() { desk = FakeDesk() }

    func describe(_ pid: pid_t, _ exe: String) -> Holder { Holders.describe(pid: pid, executable: exe, world: desk.world) }

    let brave = "/Applications/Brave Browser.app"
    let renderer = "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Versions/1/Helpers/Brave Browser Helper (Renderer).app/Contents/MacOS/Brave Browser Helper (Renderer)"
    let xcode = "/Applications/Xcode.app"
    let homebrewPython = "/opt/homebrew/Cellar/python@3.13/3.13.7/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python"

    func testMainProcessOfARunningApp() {
        desk.run(100, "/Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app", "com.adobe.LightroomClassic", "Adobe Lightroom Classic")
        let h = describe(100, "/Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app/Contents/MacOS/Adobe Lightroom Classic")
        XCTAssertTrue(h.isApp)
        XCTAssertEqual(h.appName, "Adobe Lightroom Classic")
        XCTAssertEqual(h.bundleID, "com.adobe.LightroomClassic")
        XCTAssertEqual(h.shortName, "Adobe Lightroom Classic")
    }

    func testHelperResolvesToTheRunningOuterApp() {
        // A Chromium renderer, three .app bundles deep, started by the browser and registered
        // with LaunchServices on its own: the Quit menu belongs to the outermost app.
        desk.run(4200, brave, "com.brave.Browser", "Brave Browser")
        desk.parents[4242] = 4200
        desk.run(4242, "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Versions/1/Helpers/Brave Browser Helper (Renderer).app",
                 "com.brave.Browser.helper.renderer", "Brave Browser Helper (Renderer)")
        let h = describe(4242, renderer)
        XCTAssertTrue(h.isApp)
        XCTAssertEqual(h.appName, "Brave Browser")
        XCTAssertEqual(h.bundleID, "com.brave.Browser")
        // The same renderer unknown to LaunchServices: still Brave's, which started it.
        desk.apps.removeAll { $0.pid == 4242 }
        XCTAssertEqual(describe(4242, renderer).bundleID, "com.brave.Browser")
    }

    func testToolStartedByARunningAppIsItsHelper() {
        // A crash handler: a plain executable inside the app, started by it.
        desk.run(4200, brave, "com.brave.Browser", "Brave Browser")
        let crashpad = "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Versions/1/Helpers/chrome_crashpad_handler"
        desk.parents[4300] = 4200
        XCTAssertEqual(describe(4300, crashpad).bundleID, "com.brave.Browser")
        desk.parents[4300] = 1
        XCTAssertFalse(describe(4300, crashpad).isApp, "orphaned: nobody's Quit menu ends it")
    }

    func testXPCServiceOfARunningApp() {
        desk.run(900, "/Applications/Lightroom.app", "com.adobe.lr", "Lightroom")
        desk.parents[901] = 1   // launchd starts XPC services
        let h = describe(901, "/Applications/Lightroom.app/Contents/XPCServices/Thumbnails.xpc/Contents/MacOS/Thumbnails")
        XCTAssertEqual(h.bundleID, "com.adobe.lr")
        // …and the XPC services of the app's own frameworks (found in review).
        desk.parents[902] = 1
        XCTAssertEqual(describe(902, "/Applications/Lightroom.app/Contents/Frameworks/LRCore.framework/Versions/A/XPCServices/Importer.xpc/Contents/MacOS/Importer").bundleID,
                       "com.adobe.lr")
        // Not a framework's XPC service when Lightroom is not running.
        desk.apps.removeAll()
        XCTAssertFalse(describe(901, "/Applications/Lightroom.app/Contents/XPCServices/Thumbnails.xpc/Contents/MacOS/Thumbnails").isApp)
    }

    func testAppleUserAppsAreApps() {
        // Preview, TextEdit, Archive Utility and Safari live under /System but have a Quit menu
        // (found in review: a PDF open in Preview on the drive was never asked about).
        desk.run(1300, "/System/Applications/Preview.app", "com.apple.Preview", "Preview")
        XCTAssertEqual(describe(1300, "/System/Applications/Preview.app/Contents/MacOS/Preview").bundleID, "com.apple.Preview")
        desk.run(1301, "/System/Library/CoreServices/Applications/Archive Utility.app", "com.apple.archiveutility", "Archive Utility")
        XCTAssertEqual(describe(1301, "/System/Library/CoreServices/Applications/Archive Utility.app/Contents/MacOS/Archive Utility").bundleID, "com.apple.archiveutility")
        desk.run(1302, "/Applications/Safari.app", "com.apple.Safari", "Safari")
        XCTAssertEqual(describe(1302, "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari").bundleID, "com.apple.Safari",
                       "Safari runs from a cryptex; LaunchServices knows it by pid")
        // WebKit's processes are system services, Safari's or not.
        XCTAssertFalse(describe(1303, "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent").isApp)
    }

    func testHomebrewPythonIsNotAnApp() {
        // QA 2026-10-11, H2: python3 from Homebrew runs from a Python.app inside its framework.
        // The menu showed "Python" holding Flitslig and the soft stage waited for it.
        let h = describe(700, homebrewPython)
        XCTAssertFalse(h.isApp)
        XCTAssertNil(h.bundleID)
        XCTAssertEqual(h.shortName, "Python")
        // Even with a GUI Python (IDLE) running from the very same bundle.
        desk.run(800, "/opt/homebrew/Cellar/python@3.13/3.13.7/Frameworks/Python.framework/Versions/3.13/Resources/Python.app", "org.python.python", "Python")
        desk.parents[700] = 650
        XCTAssertFalse(describe(700, homebrewPython).isApp, "the command line is not the GUI app")
    }

    func testXcodeToolchainIsNotXcode() {
        // QA 2026-10-11, H2: with xcode-select pointing into Xcode.app, /usr/bin/git, swift and
        // clang run from inside it. A git writing to the RAID resolved to Xcode, and the guard
        // would have sent the owner's IDE a quit.
        desk.run(500, xcode, "com.apple.dt.Xcode", "Xcode")
        desk.run(602, "/System/Applications/Utilities/Terminal.app", "com.apple.Terminal", "Terminal")
        desk.parents[600] = 601   // git ← zsh ← Terminal
        desk.parents[601] = 602
        for tool in ["/Applications/Xcode.app/Contents/Developer/usr/bin/git",
                     "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend",
                     "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"] {
            let h = describe(600, tool)
            XCTAssertFalse(h.isApp, tool)
            XCTAssertNil(h.bundleID, tool)
        }
        // SourceKit's XPC service sits deep in Xcode's toolchain and launchd starts it for VS
        // Code: not one of Xcode's own services.
        desk.parents[78513] = 1
        XCTAssertFalse(describe(78513, "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/sourcekitd.framework/Versions/A/XPCServices/SourceKitService.xpc/Contents/MacOS/SourceKitService").isApp)
        // Xcode's own XPC services are Xcode's.
        XCTAssertEqual(describe(510, "/Applications/Xcode.app/Contents/XPCServices/IDEFoo.xpc/Contents/MacOS/IDEFoo").bundleID, "com.apple.dt.Xcode")
        // The same git started by Xcode itself (its source control) is Xcode's.
        desk.parents[600] = 500
        XCTAssertEqual(describe(600, "/Applications/Xcode.app/Contents/Developer/usr/bin/git").bundleID, "com.apple.dt.Xcode")
    }

    func testHelperAppRunningOnItsOwnIsItself() {
        // A login-item helper registered with LaunchServices while its main app is not running.
        let path = "/Applications/1Password.app/Contents/Library/LoginItems/1Password Browser Helper.app"
        desk.run(1200, path, "com.1password.browser-helper", "1Password Browser Helper")
        let h = describe(1200, path + "/Contents/MacOS/1Password Browser Helper")
        XCTAssertEqual(h.bundleID, "com.1password.browser-helper")
        XCTAssertEqual(h.appName, "1Password Browser Helper")
    }

    func testBackgroundOnlyProcessesAreNotApps() {
        // LaunchServices lists sharingd, Finder extensions and crash reporters too, with no UI:
        // nothing to quit from a menu, so nothing to wait for.
        desk.run(1082, "/usr/libexec", "com.apple.sharingd", "sharingd", background: true)
        XCTAssertFalse(describe(1082, "/usr/libexec/sharingd").isApp)
        let ext = "/Applications/WhatsApp.app/Contents/PlugIns/ServiceExtension.appex/Contents/MacOS/ServiceExtension"
        desk.run(4025, "/Applications/WhatsApp.app/Contents/PlugIns/ServiceExtension.appex", "net.whatsapp.WhatsApp.ServiceExtension", "ServiceExtension", background: true)
        XCTAssertFalse(describe(4025, ext).isApp, "its app is not running")
        desk.run(4000, "/Applications/WhatsApp.app", "net.whatsapp.WhatsApp", "WhatsApp")
        XCTAssertEqual(describe(4025, ext).bundleID, "net.whatsapp.WhatsApp", "with its app running, the app's Quit ends it")
        // A menu bar app (accessory) has a Quit, in its menu.
        desk.run(1974, "/Users/me/Library/Application Support/iStat Menus 7/iStat Menus Menubar.app", "com.bjango.istatmenus.status", "iStat Menus Menubar")
        XCTAssertTrue(describe(1974, "/Users/me/Library/Application Support/iStat Menus 7/iStat Menus Menubar.app/Contents/MacOS/iStat Menus Menubar").isApp)
    }

    func testDaemonIsNotAnApp() {
        let h = describe(200, "/usr/sbin/smbd")
        XCTAssertFalse(h.isApp)
        XCTAssertNil(h.appName)
        XCTAssertNil(h.bundleID)
        XCTAssertEqual(h.shortName, "smbd")
        XCTAssertEqual(h.appKey, "200")
    }

    func testSystemAppsAreLeftAlone() {
        // Dock, Spotlight, Control Center, loginwindow: .app bundles under /System that nobody
        // quits, even when LaunchServices lists them as running.
        for (i, exe) in ["/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",
                         "/System/Library/CoreServices/Spotlight.app/Contents/MacOS/Spotlight",
                         "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
                         "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow",
                         "/System/Library/PrivateFrameworks/Foo.framework/XPCServices/foo.xpc/Contents/MacOS/foo",
                         "/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework/Versions/A/Resources/MobileDeviceUpdater.app/Contents/MacOS/MobileDeviceUpdater"].enumerated() {
            let pid = pid_t(300 + i)
            desk.run(pid, (exe as NSString).deletingLastPathComponent, "com.apple.thing\(i)", "Thing")
            let h = describe(pid, exe)
            XCTAssertFalse(h.isApp, exe)
            XCTAssertNil(h.bundleID, exe)
        }
    }

    func testFinderIsNotAnAppAndAlwaysKept() {
        // Finder lives under /System too, so it is not an app to the resolver; the policy's
        // always-kept list is the second line of defence for the holder that is one.
        let h = describe(300, "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder")
        XCTAssertFalse(h.isApp)
        let finder = Holder(pid: 300, executable: h.executable, appName: "Finder", bundleID: "com.apple.finder")
        XCTAssertTrue(Policy().isNeverQuit(finder))
    }

    func testUnreadablePathIsNotAnApp() {
        let h = describe(999_999, "pid 999999")
        XCTAssertFalse(h.isApp)
        XCTAssertEqual(h.shortName, "pid 999999")
    }

    func testThisProcessIsDescribedThroughLaunchServices() {
        // The real system, once: the test runner is a running process, whatever LaunchServices
        // makes of it.
        let exe = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
        let h = Holders.describe(pid: getpid(), executable: exe)
        XCTAssertEqual(h.pid, getpid())
        XCTAssertEqual(h.executable, exe)
    }

    // MARK: Asking to quit

    @MainActor
    func testQuitGoesToTheAppByBundleID() {
        desk.run(4200, brave, "com.brave.Browser", "Brave Browser")
        desk.parents[4242] = 4200
        let h = describe(4242, renderer)
        XCTAssertEqual(Holders.requestQuit(h, world: desk.world), .sent)
        XCTAssertEqual(desk.terminated, [4200], "the browser, not its renderer")
        desk.refuses = [4200]
        XCTAssertEqual(Holders.requestQuit(h, world: desk.world), .notSent)
    }

    @MainActor
    func testAHolderLaunchServicesDoesNotKnowIsNotAskedAndNothingWaits() {
        // QA 2026-10-11, H1: this used to fall back to an AppleScript "tell application id … to
        // quit", which blocked the main thread for the 120 s Apple event timeout.
        let ghost = Holder(pid: 700, executable: homebrewPython, appName: "Python", bundleID: "org.python.python")
        let t0 = Date()
        XCTAssertEqual(Holders.requestQuit(ghost, world: desk.world), .notAnApp)
        XCTAssertEqual(Holders.requestQuit(describe(700, homebrewPython), world: desk.world), .notAnApp)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1)
        XCTAssertTrue(desk.terminated.isEmpty)
    }

    func testNoAppleScriptOrAppleEventCallsInTheHolderCode() throws {
        // H1's fallback must not come back: compiling an AppleScript fetches the target's
        // terminology over an Apple event, which a process that never answers holds for two
        // minutes, on whatever thread asked. Quitting goes through NSRunningApplication only.
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/NimbusUpsBarKit/Holders.swift")
        let code = try String(contentsOf: source, encoding: .utf8)
            .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        for banned in ["NSAppleScript", "AESend", "NSAppleEventDescriptor", "OSAScript"] {
            XCTAssertFalse(code.contains(banned), "\(banned) in Holders.swift")
        }
    }
}
