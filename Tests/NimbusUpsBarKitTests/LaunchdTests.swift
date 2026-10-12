// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import NimbusUpsBarKit

/// When does launchd's account of the agent mean it failed to start the app? Both fixtures are
/// `launchctl print gui/501/com.njoubert.nimbusupsbar.agent` from this desk on 2026-10-11 (trimmed).
final class LaunchdTests: XCTestCase {

    /// After the login at 21:06: a development copy with the release's bundle identifier had
    /// taken over the Login Items record, the first spawn died of a Launch Constraint Violation,
    /// and every retry since failed with EX_CONFIG. Nothing was running.
    let failed = """
    gui/501/com.njoubert.nimbusupsbar.agent = {
    \tactive count = 0
    \tpath = (submitted by smd.384)
    \ttype = Submitted
    \tmanaged_by = com.apple.xpc.ServiceManagement
    \tstate = spawn scheduled

    \tprogram identifier = Contents/MacOS/NimbusUpsBar (mode: 2)
    \tparent bundle identifier = com.njoubert.nimbusupsbar
    \tparent bundle version = 63
    \tBTM uuid = D1F27C9C-AF83-4968-9011-2FF31AB739B2
    \tdomain = gui/501 [100025]
    \tasid = 100025
    \tminimum runtime = 10
    \texit timeout = 5
    \truns = 12
    \tlast exit code = 78: EX_CONFIG

    \tsemaphores = {
    \t\tsuccessful exit => 0
    \t}

    \tresource coalition = {
    \t\tID = 1023
    \t\ttype = resource
    \t\tstate = active
    \t\tactive count = 1
    \t}
    }
    """

    /// At 22:32, after the owner turned Run in Background off and on again from /Applications.
    let running = """
    gui/501/com.njoubert.nimbusupsbar.agent = {
    \tactive count = 4
    \tpath = (submitted by smd.384)
    \ttype = Submitted
    \tmanaged_by = com.apple.xpc.ServiceManagement
    \tstate = running

    \tprogram identifier = Contents/MacOS/NimbusUpsBar (mode: 2)
    \tparent bundle identifier = com.njoubert.nimbusupsbar
    \tparent bundle version = 63
    \tBTM uuid = B623254E-2048-4D84-921E-4779E138DCCB
    \tdomain = gui/501 [100025]
    \truns = 1
    \tpid = 7174
    \timmediate reason = speculative
    \tlast exit code = (never exited)
    \tjob state = running
    }
    """

    func testTheLoginThatNeverStartedIsAFailure() {
        XCTAssertEqual(LaunchdJob.startFailure(failed), "exit code 78: EX_CONFIG")
    }

    func testARunningAgentIsNot() {
        XCTAssertNil(LaunchdJob.startFailure(running))
    }

    func testAQuitIsNotAFailure() {
        // The menu's Quit, or the newest copy taking over: exit 0, and KeepAlive leaves it be.
        let quit = running.replacingOccurrences(of: "\tstate = running", with: "\tstate = not running")
            .replacingOccurrences(of: "\tlast exit code = (never exited)", with: "\tlast exit code = 0")
        XCTAssertNil(LaunchdJob.startFailure(quit))
    }

    func testACrashIsNotAFailureToStart() {
        // A signal is a crash; KeepAlive restarts it ten seconds later.
        let crashed = running.replacingOccurrences(of: "\tstate = running", with: "\tstate = spawn scheduled")
            .replacingOccurrences(of: "\tlast exit code = (never exited)", with: "\tlast terminating signal = Killed: 9")
        XCTAssertNil(LaunchdJob.startFailure(crashed))
    }

    func testNoJobIsNoVerdict() {
        // Not loaded (agent off, or between launchd dropping the job and Login Items resubmitting it).
        XCTAssertNil(LaunchdJob.startFailure(nil))
    }
}
