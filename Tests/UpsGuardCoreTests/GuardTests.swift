// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import UpsGuardCore

/// A fake desk: a clock we advance by hand, volumes we mount and unmount, holders we invent,
/// and actions that only record themselves. Every scenario below runs against this.
final class FakeEnvironment: GuardEnvironment {
    var now: TimeInterval = 1000
    var volumes: [String: VolumeState] = [:]
    var holderLists: [String: [Holder]] = [:]
    var quits: [String] = []
    var unmounts: [String] = []
    var mounts: [String] = []
    var awake: [Bool] = []
    var notifications: [String] = []
    var performed: [Policy.AfterSafe] = []
    var lines: [String] = []
    var unmountFails: Set<String> = []
    var mountFails: Set<String> = []
    /// Apps that really quit when asked (drop their holders), by appKey.
    var quitsWhenAsked: Set<String> = []
    /// Defer completions until `flush()` to model the asynchronous Disk Arbitration callbacks.
    var deferCompletions = false
    private var pending: [() -> Void] = []
    /// Run on every `protectedVolumes()` call: a hook for re-entering the guard mid-tick.
    var onProtectedVolumes: (() -> Void)?
    var protectedVolumesCalls = 0
    /// When set, a completion reports success but the volume's state only flips at the next
    /// `settle()`: Disk Arbitration's description change trailing the completion.
    var lagsState = false
    private var lagged: [() -> Void] = []

    func add(_ v: VolumeState, holders: [Holder] = []) {
        volumes[v.uuid] = v
        holderLists[v.uuid] = holders
    }

    func protectedVolumes() -> [VolumeState] {
        protectedVolumesCalls += 1
        onProtectedVolumes?()
        return volumes.values.sorted { $0.name < $1.name }
    }
    func holders(of volume: VolumeState) -> [Holder] { holderLists[volume.uuid] ?? [] }
    func requestQuit(_ holder: Holder) {
        quits.append(holder.appKey)
        if quitsWhenAsked.contains(holder.appKey) {
            for (k, list) in holderLists { holderLists[k] = list.filter { $0.appKey != holder.appKey } }
        }
    }
    func unmount(_ volume: VolumeState, completion: @escaping (Result<Void, GuardError>) -> Void) {
        unmounts.append(volume.name)
        let done = { [self] in
            if unmountFails.contains(volume.uuid) { completion(.failure(GuardError("dissented by smbd"))); return }
            setState(volume.uuid) { $0.mountPoint = nil }
            completion(.success(()))
        }
        if deferCompletions { pending.append(done) } else { done() }
    }
    func mount(_ volume: VolumeState, completion: @escaping (Result<Void, GuardError>) -> Void) {
        mounts.append(volume.name)
        let done = { [self] in
            if mountFails.contains(volume.uuid) { completion(.failure(GuardError("not attached"))); return }
            setState(volume.uuid) { $0.mountPoint = "/Volumes/\($0.name)" }
            completion(.success(()))
        }
        if deferCompletions { pending.append(done) } else { done() }
    }
    private func setState(_ uuid: String, _ change: @escaping (inout VolumeState) -> Void) {
        let apply = { [self] in var v = volumes[uuid]!; change(&v); volumes[uuid] = v }
        if lagsState { lagged.append(apply) } else { apply() }
    }
    func flush() { let p = pending; pending = []; p.forEach { $0() } }
    /// The lagging state catches up with the completions.
    func settle() { let l = lagged; lagged = []; l.forEach { $0() } }
    func setAwakeHold(_ on: Bool) { awake.append(on) }
    func notify(title: String, body: String) { notifications.append(title) }
    func perform(_ action: Policy.AfterSafe) { performed.append(action) }
    func log(_ line: String) { lines.append(line) }
}

final class GuardTests: XCTestCase {
    var env: FakeEnvironment!
    var guardian: OutageGuard!
    let flitslig = VolumeState(uuid: "B2D1", name: "Flitslig", bsdName: "disk9s1", mountPoint: "/Volumes/Flitslig")
    let lightroom = Holder(pid: 100, executable: "/Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app/Contents/MacOS/Adobe Lightroom Classic", appName: "Adobe Lightroom Classic", bundleID: "com.adobe.LightroomClassic")
    let smbd = Holder(pid: 200, executable: "/usr/sbin/smbd")
    let finder = Holder(pid: 300, executable: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", appName: "Finder", bundleID: "com.apple.finder")

    override func setUp() {
        env = FakeEnvironment()
        guardian = OutageGuard(environment: env, policy: Policy())
    }

    func ac(_ pct: Int = 100, runtime: Int = 190 * 60) -> UPSReading {
        UPSReading(present: true, name: "CP1500", onBattery: false, chargePercent: pct, runtimeSeconds: runtime)
    }
    func battery(_ pct: Int = 95, runtime: Int = 100 * 60) -> UPSReading {
        UPSReading(present: true, name: "CP1500", onBattery: true, chargePercent: pct, runtimeSeconds: runtime)
    }
    /// Advance the fake clock and tick, in steps, the way the app's timer would.
    func run(_ reading: UPSReading, for seconds: TimeInterval, step: TimeInterval = 5) {
        var t: TimeInterval = 0
        while t < seconds { env.now += step; t += step; guardian.tick(reading) }
    }
    /// Tick on battery every 5 s until `elapsed` seconds into the outage (the first tick
    /// starts it), so a scenario can say "at 125 s" and mean exactly that.
    func onBattery(until elapsed: TimeInterval, _ reading: UPSReading? = nil) {
        let r = reading ?? battery()
        if guardian.status.outageStart == nil { env.now += 5; guardian.tick(r) }
        while env.now - guardian.status.outageStart! < elapsed { env.now += 5; guardian.tick(r) }
    }

    // MARK: Scenarios

    func testLinePowerDoesNothing() {
        env.add(flitslig, holders: [lightroom, smbd])
        guardian.tick(ac())
        run(ac(), for: 600)
        XCTAssertEqual(guardian.status.phase, .line)
        XCTAssertTrue(env.unmounts.isEmpty)
        XCTAssertTrue(env.quits.isEmpty)
        XCTAssertTrue(env.awake.isEmpty)
    }

    func testBlipOnlyNotifies() {
        env.add(flitslig, holders: [lightroom, smbd])
        guardian.tick(ac())
        onBattery(until: 45)
        XCTAssertEqual(guardian.status.phase, .holding)
        XCTAssertEqual(env.awake, [true])
        XCTAssertEqual(guardian.status.untilSoft!, 75, accuracy: 0.01)
        run(ac(), for: 5)
        XCTAssertEqual(guardian.status.phase, .holding, "line power has to stay back before the outage is over")
        XCTAssertEqual(guardian.status.untilStandDown!, 30, accuracy: 0.01, "counted from the first reading on line")
        run(ac(), for: 30)
        XCTAssertEqual(guardian.status.phase, .line)
        XCTAssertTrue(env.unmounts.isEmpty)
        XCTAssertTrue(env.quits.isEmpty)
        XCTAssertEqual(env.awake, [true, false])
        XCTAssertEqual(env.notifications, ["Power outage", "Power restored"])
        XCTAssertEqual(guardian.status.lastOutageSeconds!, 80, accuracy: 0.01)   // 45 s on battery, then 30 s of line power to be sure
    }

    func testSoftStageQuitsAppThenUnmountsThenRemounts() {
        env.add(flitslig, holders: [lightroom, smbd, finder])
        env.quitsWhenAsked = [lightroom.appKey]
        guardian.tick(ac())
        onBattery(until: 115)
        XCTAssertEqual(guardian.status.phase, .holding)
        XCTAssertTrue(env.quits.isEmpty)
        onBattery(until: 120)                         // the grace period ends: apps are asked
        XCTAssertEqual(env.quits, [lightroom.appKey])  // Finder and smbd are never asked
        XCTAssertTrue(env.unmounts.isEmpty, "the holders were read before the ask; the next look sees Lightroom gone")
        onBattery(until: 125)
        XCTAssertEqual(env.unmounts, ["Flitslig"])
        XCTAssertEqual(guardian.status.phase, .safe)
        XCTAssertEqual(env.awake, [true, false])
        XCTAssertTrue(env.performed.isEmpty)           // keepRunning
        // Power back, and staying back: remount.
        run(ac(), for: 35)
        XCTAssertEqual(env.mounts, ["Flitslig"])
        XCTAssertEqual(guardian.status.phase, .line)
        XCTAssertTrue(env.volumes["B2D1"]!.isMounted)
        XCTAssertFalse(guardian.status.volumes[0].unmountedByGuard)
    }

    func testAppThatNeverQuitsIsForcedAtHardLimit() {
        env.add(flitslig, holders: [lightroom, smbd])
        guardian.tick(ac())
        onBattery(until: 125)
        XCTAssertEqual(guardian.status.phase, .soft)
        XCTAssertEqual(env.quits, [lightroom.appKey])
        XCTAssertEqual(guardian.status.waitingFor, ["Adobe Lightroom Classic"])
        onBattery(until: 295)
        XCTAssertEqual(guardian.status.phase, .soft)
        XCTAssertTrue(env.unmounts.isEmpty)
        XCTAssertEqual(env.quits.count, 1, "an app is asked once per outage")
        onBattery(until: 300)                         // the hard limit
        XCTAssertEqual(env.unmounts, ["Flitslig"])
        XCTAssertEqual(guardian.status.phase, .safe)
        XCTAssertTrue(env.lines.contains { $0.hasPrefix("hard limit") })
    }

    func testLowChargeTriggersHardLimit() {
        env.add(flitslig, holders: [lightroom])
        guardian.tick(ac())
        onBattery(until: 10, battery(45))              // first 15 s: readings are ignored
        XCTAssertEqual(guardian.status.phase, .holding)
        XCTAssertTrue(env.unmounts.isEmpty)
        onBattery(until: 20, battery(45))              // 45 % <= 50 %
        XCTAssertEqual(env.unmounts, ["Flitslig"])
        XCTAssertTrue(env.quits.isEmpty, "the hard limit does not wait on apps")
    }

    func testLowRuntimeTriggersHardLimit() {
        env.add(flitslig)
        guardian.tick(ac())
        onBattery(until: 20, battery(90, runtime: 9 * 60))
        XCTAssertEqual(env.unmounts, ["Flitslig"])
    }

    func testJunkReadingsRightAfterTransferAreIgnored() {
        env.add(flitslig)
        guardian.tick(ac())
        onBattery(until: 10, battery(0, runtime: 0))
        XCTAssertTrue(env.unmounts.isEmpty)
        onBattery(until: 30, battery(95, runtime: 6000))
        XCTAssertTrue(env.unmounts.isEmpty)
        XCTAssertEqual(guardian.status.phase, .holding)
    }

    func testUPSVanishingDuringOutageForcesUnmount() {
        env.add(flitslig, holders: [lightroom])
        guardian.tick(ac())
        run(battery(), for: 30)
        run(.absent(), for: 5)
        XCTAssertTrue(env.unmounts.isEmpty, "a USB re-enumeration drops the UPS for a moment; that is not the battery dying")
        XCTAssertEqual(guardian.status.phase, .holding)
        XCTAssertEqual(guardian.status.upsAbsentFor!, 0, accuracy: 0.01, "counted from the first absent reading")
        run(.absent(), for: 10)                       // gone for 10 s now
        XCTAssertEqual(env.unmounts, ["Flitslig"])
        XCTAssertEqual(guardian.status.phase, .safe)
        XCTAssertFalse(guardian.status.upsPresent)
        // The UPS comes back on line power: outage over once that holds, remount.
        run(ac(), for: 35)
        XCTAssertEqual(env.mounts, ["Flitslig"])
        XCTAssertEqual(guardian.status.phase, .line)
    }

    func testUPSUnpluggedOnLinePowerIsNotAnOutage() {
        env.add(flitslig)
        guardian.tick(ac())
        run(.absent(), for: 300)
        XCTAssertEqual(guardian.status.phase, .line)
        XCTAssertFalse(guardian.status.upsPresent)
        XCTAssertTrue(env.unmounts.isEmpty)
    }

    func testNothingMountedIsSafeAtOnce() {
        var v = flitslig; v.mountPoint = nil
        env.add(v)
        guardian.tick(ac())
        run(battery(), for: 5)
        XCTAssertEqual(guardian.status.phase, .safe)
        XCTAssertTrue(env.awake.isEmpty, "no hold when there is nothing to unmount")
        run(ac(), for: 30)
        XCTAssertTrue(env.mounts.isEmpty, "we did not unmount it, so we do not remount it")
    }

    func testPostponeShiftsSoftAndHardButNotCharge() {
        env.add(flitslig, holders: [lightroom])
        guardian.tick(ac())
        onBattery(until: 60)
        guardian.postpone(seconds: 300)
        onBattery(until: 360)                         // would have been hard at 300
        XCTAssertEqual(guardian.status.phase, .holding)
        XCTAssertTrue(env.quits.isEmpty)
        onBattery(until: 425)                         // soft at 420
        XCTAssertEqual(guardian.status.phase, .soft)
        onBattery(until: 430, battery(40))            // the charge limit still bites
        XCTAssertEqual(env.unmounts, ["Flitslig"])
    }

    func testUnmountNowFromTheMenu() {
        env.add(flitslig, holders: [lightroom])
        guardian.tick(ac())
        run(battery(), for: 10)
        guardian.unmountNow()
        XCTAssertEqual(env.unmounts, ["Flitslig"])
        XCTAssertEqual(guardian.status.phase, .safe)
    }

    func testUnmountNowOnLinePowerIsIgnored() {
        env.add(flitslig)
        guardian.tick(ac())
        guardian.unmountNow()
        XCTAssertTrue(env.unmounts.isEmpty)
    }

    func testSkipQuittingAppsWaitsForHardLimit() {
        env.add(flitslig, holders: [lightroom])
        env.quitsWhenAsked = [lightroom.appKey]
        guardian.tick(ac())
        onBattery(until: 60)
        guardian.skipQuittingAppsThisOutage()
        onBattery(until: 260)                         // soft stage
        XCTAssertTrue(env.quits.isEmpty)
        XCTAssertTrue(env.unmounts.isEmpty)
        XCTAssertFalse(guardian.status.quitAppsThisOutage)
        onBattery(until: 300)
        XCTAssertEqual(env.unmounts, ["Flitslig"])
    }

    func testPolicyWithoutQuittingUnmountsOnlyFreeVolumes() {
        guardian.policy.quitApps = false
        let other = VolumeState(uuid: "AAAA", name: "Archive", bsdName: "disk11s1", mountPoint: "/Volumes/Archive")
        env.add(flitslig, holders: [lightroom])
        env.add(other, holders: [smbd])
        guardian.tick(ac())
        onBattery(until: 120)
        XCTAssertTrue(env.quits.isEmpty)
        XCTAssertEqual(env.unmounts, ["Archive"], "the daemon-only volume goes; Lightroom's waits")
        onBattery(until: 300)
        XCTAssertEqual(env.unmounts, ["Archive", "Flitslig"])
    }

    func testFinderIsNeverAskedAndNeverWaitedFor() {
        env.add(flitslig, holders: [finder, smbd])
        guardian.tick(ac())
        onBattery(until: 120)
        XCTAssertTrue(env.quits.isEmpty)
        XCTAssertEqual(env.unmounts, ["Flitslig"])
    }

    func testAfterSafeSleepWaitsOutTheGrace() {
        guardian.policy.afterSafe = .sleep
        var v = flitslig; v.mountPoint = nil
        env.add(v)
        guardian.tick(ac())
        onBattery(until: 30)
        XCTAssertEqual(guardian.status.phase, .safe)
        XCTAssertTrue(env.performed.isEmpty, "a 30 s blip must not sleep the Mac")
        onBattery(until: 120)
        XCTAssertEqual(env.performed, [.sleep])
        onBattery(until: 220)
        XCTAssertEqual(env.performed, [.sleep], "once per outage")
    }

    func testAsynchronousUnmountIsTrackedInFlight() {
        env.deferCompletions = true
        env.add(flitslig)
        guardian.tick(ac())
        onBattery(until: 120)
        XCTAssertEqual(env.unmounts, ["Flitslig"])
        XCTAssertTrue(guardian.status.volumes[0].inFlight)
        onBattery(until: 130)
        XCTAssertEqual(env.unmounts, ["Flitslig"], "not asked again while in flight")
        XCTAssertNotEqual(guardian.status.phase, .safe)
        env.flush()                                   // the callback lands: safe at once
        XCTAssertEqual(guardian.status.phase, .safe)
        XCTAssertFalse(guardian.status.volumes[0].inFlight)
    }

    func testFailedUnmountIsRetriedAndReported() {
        env.add(flitslig)
        env.unmountFails = ["B2D1"]
        guardian.tick(ac())
        onBattery(until: 120)
        XCTAssertEqual(guardian.status.volumes[0].lastError, "dissented by smbd")
        XCTAssertEqual(guardian.status.phase, .soft)
        onBattery(until: 135)
        XCTAssertEqual(env.unmounts.count, 2, "keeps trying, every 10 s rather than every tick")
        XCTAssertEqual(env.notifications.filter { $0.hasSuffix("will not unmount") }.count, 1, "told once")
        env.unmountFails = []
        onBattery(until: 145)
        XCTAssertEqual(guardian.status.phase, .safe)
    }

    func testRemountRetriesEveryThirtySecondsAndMacOSRemountCounts() {
        env.add(flitslig)
        guardian.tick(ac())
        onBattery(until: 120)
        XCTAssertEqual(guardian.status.phase, .safe)
        env.mountFails = ["B2D1"]
        run(ac(), for: 35)
        XCTAssertEqual(env.mounts, ["Flitslig"])
        XCTAssertEqual(guardian.status.phase, .line)
        run(ac(), for: 20)
        XCTAssertEqual(env.mounts.count, 1, "not before 30 s")
        run(ac(), for: 15)
        XCTAssertEqual(env.mounts.count, 2)
        // The enclosure rebooted and macOS mounted it by itself.
        var v = env.volumes["B2D1"]!; v.mountPoint = "/Volumes/Flitslig"; env.volumes["B2D1"] = v
        run(ac(), for: 5)
        XCTAssertFalse(guardian.status.volumes[0].unmountedByGuard)
    }

    func testDetachedVolumeWaitsForTheDiskToComeBack() {
        env.add(flitslig)
        guardian.tick(ac())
        onBattery(until: 120)
        var v = env.volumes["B2D1"]!; v.isAttached = false; v.bsdName = nil; env.volumes["B2D1"] = v
        run(ac(), for: 150)
        XCTAssertTrue(env.mounts.isEmpty, "cannot mount a disk that is not there")
        XCTAssertEqual(guardian.status.phase, .line)
        XCTAssertTrue(guardian.status.volumes[0].unmountedByGuard)
        v.isAttached = true; v.bsdName = "disk12s1"; env.volumes["B2D1"] = v
        run(ac(), for: 5)
        XCTAssertEqual(env.mounts, ["Flitslig"])
    }

    func testSecondOutageStartsClean() {
        env.add(flitslig, holders: [lightroom])
        env.quitsWhenAsked = [lightroom.appKey]
        guardian.tick(ac())
        onBattery(until: 130)
        run(ac(), for: 35)
        env.holderLists["B2D1"] = [lightroom]       // Lightroom reopened the catalog
        onBattery(until: 60)
        XCTAssertEqual(guardian.status.phase, .holding, "the clock restarted")
        onBattery(until: 125)
        XCTAssertEqual(env.quits, [lightroom.appKey, lightroom.appKey], "asked again in the new outage")
    }

    // MARK: Flaky signals

    func testFlappingMainsKeepsTheOutageAndItsLimits() {
        // A brownout: 10 s on battery, 4 s on line, over and over, with the charge falling.
        // Before the hysteresis every flap reset the clock and the limits; the battery drained
        // with nothing protected and two notifications per flap.
        guardian.policy = Policy(hardAfterSeconds: 3600)
        env.add(flitslig, holders: [lightroom])
        guardian.tick(ac())
        var charge = 95
        var t: TimeInterval = 0
        while t < 14 * 60, env.unmounts.isEmpty {
            for _ in 0..<5 { env.now += 2; t += 2; guardian.tick(battery(charge)) }
            for _ in 0..<2 { env.now += 2; t += 2; guardian.tick(ac(charge)) }
            charge = max(20, charge - 1)
        }
        XCTAssertEqual(env.unmounts, ["Flitslig"], "the charge limit fired")
        XCTAssertTrue(guardian.status.hardReasons.contains { $0.hasPrefix("charge at") }, "\(guardian.status.hardReasons)")
        XCTAssertEqual(env.quits, [lightroom.appKey], "asked once, at the end of one grace period, not once per flap")
        XCTAssertEqual(env.notifications.filter { $0 == "Power outage" }.count, 1)
        XCTAssertEqual(env.notifications.filter { $0 == "Power restored" }.count, 0)
        XCTAssertLessThan(t, 14 * 60, "it did not take the whole brownout")
    }

    func testLimitsAreJudgedAgainstTheLastBatteryReadingDuringAFlap() {
        env.add(flitslig)
        guardian.tick(ac())
        onBattery(until: 60, battery(55))
        run(ac(100), for: 4)                          // line back, and the UPS reports 100 % again at once
        run(battery(45), for: 2)                      // 45 % on the next reading on battery
        XCTAssertEqual(env.unmounts, ["Flitslig"])
    }

    func testLinePowerHasToStayBackBeforeStandingDown() {
        env.add(flitslig, holders: [lightroom])
        guardian.tick(ac())
        onBattery(until: 60)
        run(ac(), for: 20)                            // readings on line at 65, 70, 75, 80 s
        XCTAssertEqual(guardian.status.phase, .holding)
        XCTAssertEqual(guardian.status.untilStandDown!, 15, accuracy: 0.01)
        XCTAssertTrue(env.lines.contains { $0.hasPrefix("line power is back; standing down in 30 s") })
        run(battery(), for: 5)                        // …and it fails again, at 85 s
        XCTAssertNil(guardian.status.untilStandDown)
        XCTAssertTrue(env.lines.contains { $0.hasPrefix("line power failed again after 20 s") }, "\(env.lines.suffix(3))")
        run(ac(), for: 35)                            // line at 90 s, trusted at 120 s
        XCTAssertEqual(guardian.status.phase, .line)
        XCTAssertEqual(env.notifications, ["Power outage", "Power restored"])
        XCTAssertEqual(guardian.status.lastOutageSeconds!, 120, accuracy: 0.01)
    }

    func testAfterSafeDoesNotRunWhilePowerIsBackButNotYetTrusted() {
        guardian.policy.afterSafe = .sleep
        var v = flitslig; v.mountPoint = nil
        env.add(v)
        guardian.tick(ac())
        onBattery(until: 115)
        XCTAssertEqual(guardian.status.phase, .safe)
        run(ac(), for: 20)                            // the grace period ends while mains is back but not yet trusted
        XCTAssertTrue(env.performed.isEmpty, "no sleeping the Mac while the power may well be back")
        run(battery(), for: 5)                        // it was not
        XCTAssertEqual(env.performed, [.sleep])
    }

    func testVolumeMountedMidOutageGetsTheSleepHold() {
        var v = flitslig; v.mountPoint = nil
        env.add(v)
        guardian.tick(ac())
        onBattery(until: 30)
        XCTAssertEqual(guardian.status.phase, .safe)
        XCTAssertTrue(env.awake.isEmpty)
        var m = env.volumes["B2D1"]!; m.mountPoint = "/Volumes/Flitslig"; env.volumes["B2D1"] = m
        onBattery(until: 35)
        XCTAssertEqual(guardian.status.phase, .holding)
        XCTAssertEqual(env.awake, [true], "the hold follows the volumes, not the transfer")
        onBattery(until: 125)
        XCTAssertEqual(env.unmounts, ["Flitslig"])
        XCTAssertEqual(env.awake, [true, false])
    }

    func testRelaunchMidOutageResumesTheClock() {
        // A crash-restart: the new copy learns from UserDefaults that the outage began 200 s
        // ago, its first tick runs before Disk Arbitration's replay (no volumes), the second
        // sees Flitslig.
        guardian.resumeElapsed = 200
        guardian.tick(battery())
        XCTAssertEqual(guardian.status.phase, .safe, "nothing to protect yet")
        XCTAssertEqual(guardian.status.elapsed, 200, accuracy: 0.01)
        XCTAssertEqual(env.notifications, ["Power outage (resumed)"])
        env.add(flitslig, holders: [lightroom])
        env.now += 2
        guardian.tick(battery())
        XCTAssertEqual(guardian.status.phase, .soft, "202 s in: the grace period is long over")
        XCTAssertEqual(env.quits, [lightroom.appKey])
        XCTAssertEqual(env.awake, [true])
        XCTAssertEqual(guardian.status.untilHard!, 98, accuracy: 0.01)
    }

    func testResumeIsDroppedByALineReading() {
        env.add(flitslig)
        guardian.resumeElapsed = 200
        guardian.tick(ac())                           // launched after the power came back
        XCTAssertNil(guardian.resumeElapsed)
        onBattery(until: 60)
        XCTAssertEqual(guardian.status.phase, .holding, "a later outage starts from zero")
    }

    func testPowerReturnsRemountInFlightThenFailsAgain() {
        env.add(flitslig)
        guardian.tick(ac())
        onBattery(until: 120)
        XCTAssertEqual(guardian.status.phase, .safe)
        env.deferCompletions = true
        run(ac(), for: 35)                            // stands down; the remount is in flight
        XCTAssertEqual(guardian.status.phase, .restoring)
        XCTAssertEqual(env.mounts, ["Flitslig"])
        run(battery(), for: 5)                        // and the power fails again
        XCTAssertEqual(guardian.status.phase, .holding, "a new outage; the mount is still in flight")
        XCTAssertEqual(env.notifications.filter { $0 == "Power outage" }.count, 2)
        env.flush()                                   // the mount lands mid-outage
        env.deferCompletions = false
        XCTAssertTrue(env.volumes["B2D1"]!.isMounted)
        onBattery(until: 125)
        XCTAssertEqual(env.unmounts, ["Flitslig", "Flitslig"], "unmounted again at this outage's grace")
        XCTAssertEqual(guardian.status.phase, .safe)
    }

    func testSafeOnlyWhenEveryVolumeHasLanded() {
        let second = VolumeState(uuid: "C3E2", name: "Archive", bsdName: "disk10s1", mountPoint: "/Volumes/Archive")
        env.add(flitslig)
        env.add(second)
        env.unmountFails = ["B2D1"]
        env.deferCompletions = true
        guardian.tick(ac())
        onBattery(until: 120)
        XCTAssertEqual(Set(env.unmounts), ["Flitslig", "Archive"])
        XCTAssertEqual(guardian.status.phase, .soft)
        env.flush()                                   // Archive lands, Flitslig fails
        XCTAssertNotEqual(guardian.status.phase, .safe)
        XCTAssertEqual(guardian.status.volumes.first { $0.volume.name == "Flitslig" }?.lastError, "dissented by smbd")
        env.unmountFails = []
        onBattery(until: 135)                         // the retry, 10 s after the failure
        env.flush()
        XCTAssertEqual(guardian.status.phase, .safe)
        XCTAssertEqual(env.unmounts.count, 3)
    }

    func testPolicyChangedMidOutageAppliesAtOnce() {
        env.add(flitslig, holders: [lightroom])
        guardian.tick(ac())
        onBattery(until: 60)
        XCTAssertEqual(guardian.status.phase, .holding)
        guardian.policy.graceSeconds = 30
        onBattery(until: 65)
        XCTAssertEqual(guardian.status.phase, .soft, "a shorter grace is already over")
        XCTAssertEqual(env.quits, [lightroom.appKey])
        guardian.policy.hardAfterSeconds = 10         // below the grace: normalized up to it
        XCTAssertEqual(guardian.policy.hardAfterSeconds, 30)
        onBattery(until: 70)
        XCTAssertEqual(env.unmounts, ["Flitslig"], "the hard limit is behind us too")
    }

    func testPostponeDuringSoftKeepsThePhase() {
        env.add(flitslig, holders: [lightroom])
        guardian.tick(ac())
        onBattery(until: 125)
        XCTAssertEqual(guardian.status.phase, .soft)
        guardian.postpone(seconds: 300)
        XCTAssertEqual(guardian.status.phase, .soft, "the apps have been asked; that is not undone")
        XCTAssertNil(guardian.status.untilSoft)
        XCTAssertEqual(guardian.status.untilHard!, 475, accuracy: 0.01)
        env.holderLists["B2D1"] = []                  // Lightroom lets go during the postponement
        onBattery(until: 130)
        XCTAssertEqual(env.unmounts, ["Flitslig"], "the soft stage keeps working")
    }

    func testReentrantTicksAreCapped() {
        env.add(flitslig)
        guardian.tick(ac())
        // Something re-enters the guard from inside every evaluation (a completion that lands
        // synchronously, a callback that ticks): the tick must end, not recurse.
        env.onProtectedVolumes = { [weak self] in self?.guardian.tick(self!.battery()) }
        env.protectedVolumesCalls = 0
        env.now += 5
        guardian.tick(battery())
        XCTAssertEqual(env.protectedVolumesCalls, OutageGuard.maxRounds)
        XCTAssertEqual(guardian.status.phase, .holding)
    }

    func testVolumeStateLaggingBehindTheCompletionIsNotUnmountedTwice() {
        env.lagsState = true
        env.add(flitslig)
        guardian.tick(ac())
        onBattery(until: 120)                         // unmount completes; the registry still says mounted
        XCTAssertEqual(env.unmounts, ["Flitslig"])
        XCTAssertNotEqual(guardian.status.phase, .safe)
        onBattery(until: 125)
        XCTAssertEqual(env.unmounts, ["Flitslig"], "not asked again while the state catches up")
        env.settle()
        onBattery(until: 130)
        XCTAssertEqual(guardian.status.phase, .safe)
        // And on the way back: the description change can land before the mount completion.
        env.lagsState = false
        env.deferCompletions = true
        run(ac(), for: 35)
        XCTAssertEqual(env.mounts, ["Flitslig"])
        var v = env.volumes["B2D1"]!; v.mountPoint = "/Volumes/Flitslig"; env.volumes["B2D1"] = v
        run(ac(), for: 2)
        XCTAssertFalse(guardian.status.volumes[0].unmountedByGuard, "mounted is mounted, whoever says so first")
        env.flush()
        XCTAssertEqual(guardian.status.phase, .line)
        XCTAssertEqual(env.mounts.count, 1)
    }

    func testHelperProcessOfAnAskedAppIsNotAskedAgain() {
        let renderer = Holder(pid: 4242,
                              executable: "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Versions/1/Helpers/Brave Browser Helper (Renderer).app/Contents/MacOS/Brave Browser Helper (Renderer)",
                              appName: "Brave Browser", bundleID: "com.brave.Browser")
        let brave = Holder(pid: 4200, executable: "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser", appName: "Brave Browser", bundleID: "com.brave.Browser")
        env.add(flitslig, holders: [renderer, brave])
        guardian.tick(ac())
        onBattery(until: 125)
        XCTAssertEqual(env.quits, [renderer.appKey], "one ask per app, whichever process was listed first")
        XCTAssertEqual(guardian.status.waitingFor, ["Brave Browser"])
    }

    // MARK: Rehearsal and simulation

    func testRehearsalTouchesNothing() {
        env.add(flitslig, holders: [lightroom, smbd])
        let rehearsal = RehearsalEnvironment(base: env, speed: 10)
        let g = OutageGuard(environment: rehearsal, policy: Policy())
        g.tick(ac())
        var t: TimeInterval = 0
        while t < 40 { env.now += 1; t += 1; g.tick(battery()) }   // 400 simulated seconds
        XCTAssertEqual(g.status.phase, .safe)
        XCTAssertTrue(env.unmounts.isEmpty)
        XCTAssertTrue(env.quits.isEmpty)
        XCTAssertTrue(env.awake.isEmpty)
        XCTAssertTrue(rehearsal.actions.contains { $0.hasPrefix("would ask Adobe Lightroom Classic") })
        XCTAssertTrue(rehearsal.actions.contains { $0.hasPrefix("would force-unmount Flitslig") })
        XCTAssertTrue(env.volumes["B2D1"]!.isMounted)
    }

    func testDrillNeverSleepsOrShutsDown() {
        env.add(flitslig)
        let drill = DrillEnvironment(base: env, speed: 10)
        var p = Policy(); p.afterSafe = .shutDown
        let g = OutageGuard(environment: drill, policy: p)
        g.tick(ac())
        var t: TimeInterval = 0
        while t < 40 { env.now += 1; t += 1; g.tick(battery()) }
        XCTAssertEqual(env.unmounts, ["Flitslig"], "a drill really unmounts")
        XCTAssertTrue(env.performed.isEmpty, "but never shuts the Mac down")
    }

    func testSimulatedOutageDrainsAndDies() {
        let sim = SimulatedOutage(template: ac(), initialRuntime: 600, speed: 10, realNow: 0)
        let r0 = sim.reading(realNow: 0, monotonicStamp: 0)
        XCTAssertTrue(r0.onBattery)
        XCTAssertEqual(r0.chargePercent, 100)
        let r1 = sim.reading(realNow: 30, monotonicStamp: 30)   // 300 simulated seconds in
        XCTAssertEqual(r1.chargePercent, 50)
        XCTAssertEqual(r1.runtimeSeconds, 300)
        let r2 = sim.reading(realNow: 61, monotonicStamp: 61)
        XCTAssertFalse(r2.present, "the UPS switches off when the battery is gone")
        sim.restorePower(realNow: 61)
        let r3 = sim.reading(realNow: 62, monotonicStamp: 62)
        XCTAssertTrue(r3.present)
        XCTAssertFalse(r3.onBattery)
    }

    func testChargeLimitOffIgnoresTheGauge() {
        guardian.policy = Policy(hardAtPercent: nil)
        env.add(flitslig, holders: [lightroom])
        guardian.tick(ac())
        onBattery(until: 60, battery(20))
        XCTAssertEqual(guardian.status.phase, .holding, "20 % is not a reason when the charge limit is off")
        XCTAssertTrue(env.unmounts.isEmpty)
        onBattery(until: 300, battery(20))
        XCTAssertEqual(env.unmounts, ["Flitslig"], "the time limit is always on")
    }

    func testRuntimeLimitOffIgnoresTheEstimate() {
        guardian.policy = Policy(hardAtRuntimeSeconds: nil)
        env.add(flitslig)
        guardian.tick(ac())
        onBattery(until: 60, battery(90, runtime: 60))
        XCTAssertEqual(guardian.status.phase, .holding)
        XCTAssertTrue(env.unmounts.isEmpty)
    }

    func testQuitTimeoutForcesAStubbornAppBeforeTheHardLimit() {
        guardian.policy = Policy(quitTimeoutSeconds: 60)
        env.add(flitslig, holders: [lightroom, smbd])
        guardian.tick(ac())
        onBattery(until: 120)                         // asked at the end of the grace
        XCTAssertEqual(env.quits, [lightroom.appKey])
        XCTAssertEqual(guardian.status.untilQuitTimeout, 60)
        XCTAssertEqual(guardian.status.untilForce, 60, "the quit timeout comes before the 180 s to the hard limit")
        onBattery(until: 175)
        XCTAssertTrue(env.unmounts.isEmpty)
        XCTAssertEqual(guardian.status.phase, .soft)
        onBattery(until: 180)                         // 60 s after the ask
        XCTAssertEqual(env.unmounts, ["Flitslig"])
        XCTAssertEqual(guardian.status.phase, .safe)
        XCTAssertEqual(env.quits.count, 1)
        XCTAssertTrue(env.lines.contains { $0.contains("did not quit within 1 min") })
        XCTAssertFalse(env.lines.contains { $0.hasPrefix("hard limit") }, "this is the soft stage giving up, not a hard limit")
    }

    func testQuitTimeoutWaitsForEveryAppOnTheVolume() {
        guardian.policy = Policy(quitTimeoutSeconds: 60)
        let photos = Holder(pid: 101, executable: "/System/Applications/Photos.app/Contents/MacOS/Photos", appName: "Photos", bundleID: "com.apple.Photos")
        env.add(flitslig, holders: [lightroom])
        guardian.tick(ac())
        onBattery(until: 120)
        env.holderLists[flitslig.uuid] = [lightroom, photos]   // Photos opens a file; asked on the next tick, at 125 s
        onBattery(until: 150)
        XCTAssertEqual(env.quits, [lightroom.appKey, photos.appKey])
        XCTAssertEqual(guardian.status.untilQuitTimeout, 35, "the volume is forced a minute after the last ask")
        onBattery(until: 180)
        XCTAssertTrue(env.unmounts.isEmpty, "Lightroom's minute is up, Photos' is not")
        onBattery(until: 185)
        XCTAssertEqual(env.unmounts, ["Flitslig"])
    }

    func testQuitTimeoutIsMootWhenAppsAreNotAsked() {
        guardian.policy = Policy(quitApps: false, quitTimeoutSeconds: 60)
        env.add(flitslig, holders: [lightroom])
        guardian.tick(ac())
        onBattery(until: 200)
        XCTAssertTrue(env.quits.isEmpty)
        XCTAssertTrue(env.unmounts.isEmpty, "nobody was asked, so nobody can have failed to quit")
        XCTAssertNil(guardian.status.untilQuitTimeout)
        onBattery(until: 300)
        XCTAssertEqual(env.unmounts, ["Flitslig"])
    }

    func testDurationParse() {
        XCTAssertEqual(Duration.parse("90"), 90)
        XCTAssertEqual(Duration.parse("90 s"), 90)
        XCTAssertEqual(Duration.parse("2 min"), 120)
        XCTAssertEqual(Duration.parse("1.5 min"), 90)
        XCTAssertEqual(Duration.parse("2m"), 120)
        XCTAssertEqual(Duration.parse("1 h 30 min"), 5400)
        XCTAssertEqual(Duration.parse("1h30m"), 5400)
        XCTAssertEqual(Duration.parse("2 min 05 s"), 125)
        XCTAssertEqual(Duration.parse("2:30"), 150)
        XCTAssertEqual(Duration.parse(" 10 MIN "), 600)
        XCTAssertNil(Duration.parse(""))
        XCTAssertNil(Duration.parse("soon"))
        XCTAssertNil(Duration.parse("5 parsecs"))
        XCTAssertNil(Duration.parse("-5 s"))
        XCTAssertNil(Duration.parse("2:75"))
        for v: TimeInterval in [45, 120, 125, 5400, 3600] { XCTAssertEqual(Duration.parse(Duration.text(v)), v, "text round-trips") }
    }

    func testDurationText() {
        XCTAssertEqual(Duration.text(45), "45 s")
        XCTAssertEqual(Duration.text(120), "2 min")
        XCTAssertEqual(Duration.text(125), "2 min 05 s")
        XCTAssertEqual(Duration.text(5400), "1 h 30 min")
        XCTAssertEqual(Duration.countdown(112), "1:52")
        XCTAssertEqual(Duration.countdown(900), "15 min")
    }

    func testPolicyNormalization() {
        var p = Policy(graceSeconds: 600, hardAfterSeconds: 300, hardAtPercent: 150)
        p = p.normalized
        XCTAssertEqual(p.hardAfterSeconds, 600, "the hard limit can never come before the grace period ends")
        XCTAssertEqual(p.hardAtPercent, 100)
        XCTAssertTrue(p.neverQuit.contains("com.apple.finder"))
        let off = Policy(hardAtPercent: nil, hardAtRuntimeSeconds: nil, quitTimeoutSeconds: -5).normalized
        XCTAssertNil(off.hardAtPercent)
        XCTAssertNil(off.hardAtRuntimeSeconds)
        XCTAssertEqual(off.quitTimeoutSeconds, 0)
        XCTAssertEqual(Policy().summary, "grace 2 min, ask apps to quit, hard at 5 min on battery or 50 % charge or 10 min runtime, readings ignored for 15 s, then keep running")
        XCTAssertEqual(off.summary, "grace 2 min, ask apps to quit, force after 0 s, hard at 5 min on battery, readings ignored for 15 s, then keep running")
    }
}
