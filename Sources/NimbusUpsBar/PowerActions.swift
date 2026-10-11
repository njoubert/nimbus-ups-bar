// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import IOKit.pwr_mgt

/// The three things the guard does to the Mac itself.
@MainActor
enum PowerActions {
    private static var assertion: IOPMAssertionID = 0

    /// Keep the Mac from idle-sleeping. The "UPS Power" pmset profile sleeps the Mac a minute
    /// after the transfer; a sleeping Mac cannot unmount anything. The display may still dim.
    static func holdAwake(_ on: Bool) {
        if on {
            guard assertion == 0 else { return }
            var id: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "Nimbus UPS Bar: unmounting protected volumes before the UPS runs out" as CFString, &id)
            if r == kIOReturnSuccess { assertion = id } else { Log.shared.append("sleep hold failed: \(r)") }
        } else {
            guard assertion != 0 else { return }
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    static var isHoldingAwake: Bool { assertion != 0 }

    /// What `pmset sleepnow` does; no privilege needed.
    static func sleep() {
        let port = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard port != 0 else { Log.shared.append("sleep: no power management port"); return }
        let r = IOPMSleepSystem(port)
        IOServiceClose(port)
        if r != kIOReturnSuccess { Log.shared.append("sleep failed: \(r)") }
    }

    /// Shut down without sudo: the shutdown Apple event to loginwindow, which puts up the
    /// usual "unsaved changes" dialogs and then powers off. Untested on this desk as of
    /// 2026-10-10; see README.
    static func shutDown() {
        let script = NSAppleScript(source: "tell application \"loginwindow\" to «event aevtshut»")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error { Log.shared.append("shutdown failed: \(error)") }
    }
}
