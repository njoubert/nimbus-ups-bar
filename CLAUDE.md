# Nimbus UPS Bar — notes for agents

A macOS menu bar guard that unmounts external drives before a UPS runs out, in Swift. Pure
SwiftPM, no Xcode project, one dependency: `NimbusUpdater` (https://github.com/njoubert/nimbus-updater,
MIT, ours). A sibling of `../nimbus-net-bar` and `../nimbus-leviton-bar`: same build pipeline,
same conventions; their CLAUDE.md files cover the shared traps (DMG layout, notarization, the
updater, menu-bar views) in more depth than this one repeats. `README.md` is the user-facing
description; read it first and keep it true when behaviour changes. This file is the rest: how
to work here, what the platform really does, and the traps already found.

The investigation this grew out of is symlinked at `2026-10-10-macbookpro-ups-outage-guard/`
on the owner's machine (a folder in `~/Troubleshoot`; the symlink is git-ignored, so a clone has
no such folder): the handoff brief, the findings, and a bash reference implementation. Read its
README before changing the policy or the stages.

## Ground rules

- **These are the owner's real drives and real apps.** Nothing in a test may quit an app or
  unmount a volume without the owner saying so for that run. The rehearsal (`--simulate`, the
  menu's Rehearse) exists so the whole state machine can be exercised against the real desk
  without touching it; use it. The drill, a manual unmount, and the self-test are the owner's
  to run. In 2026-10-10's investigation a dry-run flag read at the wrong time sent a real quit to
  Lightroom Classic while it was in use; that is why `RehearsalEnvironment` is a separate
  environment object and not a flag.
- **Install nothing that runs unattended until the owner has reviewed the code.** `--enable-agent`
  and `build.sh install` register a launchd agent that runs at every login; do not run them on the
  owner's behalf.
- **Grill me relentlessly** before building a feature: every question whose answer would change
  the work, with the facts already checked. Decisions, not options.
- **Be concise.** Short reports, the salient facts only.
- **`prek` (pre-commit) must pass.** `prek install` once, then `prek run --all-files` before
  claiming done. Shellcheck at its default severity. Never disable a hook to get past it.
- **`swift test` must pass**, and a change to `OutageGuard` or `Policy` without a scenario in
  `Tests/UpsGuardCoreTests/GuardTests.swift` is not finished. The tests are the only place the
  outage paths run without an outage.
- **Licence headers.** Every new Swift file starts with `// Copyright (C) 2026 Niels Joubert` /
  `// SPDX-License-Identifier: GPL-3.0-or-later`. GPL-3.0-or-later; don't vendor incompatible code.
- **It talks to nothing but GitHub, and only for updates.** `api.github.com` plus
  `release-assets.githubusercontent.com` unless *Check for Updates Automatically* is off. README
  must keep saying exactly this.
- **Resolve volumes by UUID**, never by `diskN` (those get reused) or by name alone.

## Layout

```
Sources/UpsGuardCore/        the library the tests drive; no AppKit, no IOKit
  Readings.swift             UPSReading (+ flags, self-test), VolumeState, Holder, GuardError
  Policy.swift               the owner's numbers and choices; normalized; never-quit list
  Environment.swift          GuardEnvironment protocol; RehearsalEnvironment (touches nothing,
                             scaled clock, pretends asked apps quit); DrillEnvironment (real
                             actions, scaled clock, never sleeps/shuts down)
  Guard.swift                OutageGuard: the phases, the limits, the owner actions, Status;
                             Duration formatting
  Simulation.swift           SimulatedOutage: a pretend UPS draining at N× that dies at 0
Sources/NimbusUpsBar/        the app
  main.swift                 flags, AppDelegate, single-instance rule, agent toggling
  CLI.swift                  --print / --print-menu / --watch / --simulate / --holders / --volumes
                             / --check-update / --preflight / --agent-plist
  Monitor.swift              UPSMonitor: timers, merging IOKit + HID readings, samples for the
                             chart, simulations; RealEnvironment (the live GuardEnvironment)
  PowerSources.swift         IOPSCopyPowerSourcesInfo + the change notification; monotonicNow()
  UPSHID.swift               the UPS over USB HID: elements keyed by section, labels, formatting,
                             the self-test write
  Volumes.swift              VolumeRegistry: Disk Arbitration callbacks, external filter,
                             force unmount, mount
  Holders.swift              proc_listpidspath → Holder; quit via NSRunningApplication
  Health.swift               the health rules → [Item] with a level
  Settings.swift             UserDefaults: policy, volume mode and selection, known volumes
  Log.swift                  the log file, the ring for Recent Events, os_log
  Notifications.swift        UNUserNotificationCenter (bundle only)
  BackgroundAgent.swift      SMAppService.agent + the plist text build.sh bakes in
  PowerActions.swift         sleep assertion, IOPMSleepSystem, the loginwindow shutdown event
  StatusBarController.swift  the bar, the menu, every submenu, menuText() for --print-menu
  HeadlineView.swift         the phase + three figures at the top of the menu
  ChartView.swift            load and charge, two panels, one hour, hover readout, outage bands
  AppIcon.swift, DMGBackground.swift, Updates.swift   as in the siblings
Tests/UpsGuardCoreTests/     27 scenarios against FakeEnvironment
docs/                        icon.png (build.sh icon); phase-2-email-notifications.md (design)
build.sh                     build / test / run / stop / app / dmg / release / install /
                             uninstall / status / icon / clean
```

Swift 5 language mode (`swift-tools-version:5.10`) with the Swift 6 compiler. UI classes and
the monitor are `@MainActor`; IOKit, DA and timer callbacks hop in with `MainActor.assumeIsolated`.
`GuardEnvironment` is not actor-isolated (the core has no actors), so `RealEnvironment` is a
plain class whose methods `assumeIsolated` their way onto the main actor, which is the thread
they are always called on. HID reads run on a utility queue (~30 ms of USB each) and publish on
main.

## Build, run, test

```
./build.sh run [--fg]         debug build as dist/debug/Nimbus UPS Bar.app (quits any running copy first)
./build.sh test               swift test: the 27 guard scenarios
./build.sh install            release → /Applications, register the agent (owner's call), launch
.build/debug/NimbusUpsBar --print        the UPS, health, every HID field, volumes, holders, policy
.build/debug/NimbusUpsBar --print-menu   the menu built against the real UPS, as an indented tree
.build/debug/NimbusUpsBar --watch        readings + the guard's log as they happen (Ctrl-C)
.build/debug/NimbusUpsBar --simulate     a rehearsal in the terminal (~30 s; touches nothing)
.build/debug/NimbusUpsBar --dump-chart P the chart with fake data → PNG (dark appearance)
```

`--print-menu` is the way to check the menu without a screen: it calls the same `rebuild()` an
open does, so a crash in a submenu shows up there. The accessibility route the siblings use
(`osascript … System Events`) needs Assistive Access for the terminal, which this machine's
terminal does not have as of 2026-10-10.

**Which copy is running matters.** The bare `.build/debug` binary has no bundle: no agent plist
(`Run in Background` is disabled, `--agent-status` says so), no notifications, and
`UserDefaults` land in a `NimbusUpsBar` domain rather than `com.njoubert.nimbusupsbar`. Test
behaviour through the bundle `build.sh run` makes.

## How the guard decides (read Guard.swift for the details)

Phases from the first reading on battery: `holding` (grace, default 120 s, nothing touched) →
`soft` (apps holding files are sent one quit each; a volume unmounts as soon as no app outside
the never-quit list holds it) → `hard` (time ≥ 300 s, charge ≤ 50 %, runtime ≤ 10 min, the UPS
vanishing, shutdown-imminent, or *Unmount Now*: force-unmount everything) → `safe` (sleep hold
released; the after-safe action once, and only after the grace period, so a blip never sleeps
the Mac) → on line power `restoring` (remount what *we* unmounted, retrying every 30 s while the
disk is attached; a macOS auto-remount counts). Readings are ignored for the first 15 s on
battery. Postpone shifts the two time limits only. Everything is force: `smbd` dissents a plain
unmount of any volume with a share point on it; force still flushes.

A completion (unmount/mount) that lands mid-tick sets `retick` and the tick runs once more at
the end, so `safe` is reached the moment the last volume lands rather than two seconds later.

## Platform facts (checked 2026-10-10 on this desk)

- **macOS ignores UPS shutdown thresholds on laptops** (`man pmset`; `pmconfigd/UPSLowPower.c`).
- **`IOPSCopyPowerSourcesInfo` lists the UPS** with `Type = UPS`, `Power Source State`, `Current
  Capacity`, `Time to Empty` (minutes; 0 = no estimate), `Voltage` (mV). `IOPSNotificationCreateRunLoopSource`
  fires on changes; it is scheduled in `.commonModes` so it fires with the menu open.
- **The IOKit entry's `Voltage` key is not the line voltage.** `ioupsd` writes whichever voltage
  element it read last: 122000 mV at one read, 27100 (the battery) a minute later. The app ignores
  it (it still shows under UPS Details › macOS power source) and takes every voltage from HID.
- **The HID report is the richer source**, read through `IOHIDManager` with a shared open
  (`ioupsd` keeps its own). 58 unique elements on the CP1500PFCLCDa; a full read is ~30 ms (11 ms
  seen). Elements are keyed by (enclosing collection, page, usage): `Voltage` 0x84/0x30 exists
  under Input, Output and the battery's PowerSummary.
- **Read with `kIOHIDDeviceGetValueWithUpdate` (0x00020000).** The plain `IOHIDDeviceGetValue`
  returns the *cached* value for Input-type elements, and the ones the UPS does not push on its
  own (self-test result, beeper, the transfer voltages, rid 12/16/20) then read 0. The first probe
  happened to see real values because something else had just requested them; the running app
  showed "Line 122 V outside the 0–0 V window" until this was found.
- **CyberPower battery volts come in tenths** once two digits (271 = 27.1 V, 240 = 24.0 V nominal);
  line volts are whole volts. NUT corrects the same quirk. Self-test values use NUT's mapping:
  1 passed, 2 warning, 3 error, 4 aborted, 5 in progress, 6 not run; writing 1 starts the quick test.
- **Starting the self-test is a raw SET_REPORT.** CyberPower declares `Test` (0x84/0x58, report
  20) as an Input element; `IOHIDDeviceSetValue` on it returns 0xe00002c2 (unsupported).
  `IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, 20, [20, 1], 2)`, the report ID as the first
  byte, is what works (NUT sends the same). Measured 2026-10-10: `Test` reads 5 (in progress) for
  11 s, then 1 (passed); `ACPresent` stays 1 throughout, so a self-test never looks like an outage
  to the guard.
- **Load is live and coarse.** `PercentLoad` is an integer percent of 1000 W; `ActivePower` in
  watts is filled too (80–105 W seen). The first read of the day showed 0 % and 190 min runtime
  while a later one showed 10 % and 72 min, so the figure moves with the display and the drives.
  The health rule flags 0 % because that is what the surge-only outlets look like.
- **`proc_listpidspath(PROC_ALL_PIDS, 0, path, PROC_LISTPIDSPATH_PATH_IS_VOLUME | …)`** is the
  native `lsof` for "who has files open on this volume": ~60 ms, no subprocess. Map with
  `proc_pidpath`. `PROC_PIDPATHINFO_MAXSIZE` does not import; 4096 is the value.
- **A quit Apple event needs no Automation permission** (verified in the investigation with
  `osascript`); `NSRunningApplication.terminate()` sends the same event. A **hardened-runtime**
  build still needs the `com.apple.security.automation.apple-events` entitlement to send any Apple
  event, so build.sh signs with it (ad-hoc builds too).
- **Disk Arbitration from Swift:** `kDADiskDescriptionMatchVolumeMountable` and
  `kDADiskDescriptionWatchVolumePath` import as `Unmanaged`; `.takeUnretainedValue()` them.
  Registering an appeared callback replays every existing disk, which is the initial enumeration.
  Disk images report `DADeviceProtocol = "Virtual Interface"` and are *not* internal, so they are
  filtered by protocol; EFI and Apple_Boot helper partitions by `DAMediaContent` GUID.
- **`SMAppService.agent(plistName:)` reports a never-registered agent as `.notFound`**, not
  `.notRegistered`. Whether the plist is in the bundle is a separate file check (`isAvailable`).
  The plist text lives in `BackgroundAgent.plist(executable:)` and build.sh writes it into
  `Contents/Library/LaunchAgents/` with `--agent-plist`; `KeepAlive = {SuccessfulExit = false}` so
  Quit (exit 0) stays quit and a crash restarts.
- **Only one copy runs.** The newest copy terminates any other with the same bundle id at launch
  (`AppDelegate`), which is what makes toggling the agent work: enabling makes launchd start a copy
  that takes over; disabling spawns `open -n` of the bundle first, then unregisters (launchd stops
  the agent's job). `--dump-bar` skips the rule so it can grab the bar beside the live copy.
- **`UNUserNotificationCenter` needs a bundle**; the bare binary logs instead (`Notifications.available`).
- **`leaks` reports ~400 leaked objects** (~20 KB) in three `NSXPCConnection` retain cycles
  (`LNDaemonApplicationInterface`, notifications / LaunchServices) right after launch. Framework
  internals, not ours; check that the count stays flat before chasing it.
- **`timeout` is not on macOS**; `--simulate` ends on its own (~30 s at 10× with the defaults).

## Verified live (2026-10-10, 18:25, plug pulled by the owner)

Transfer seen within seconds; `holding` for the 2 min grace; Lightroom Classic (catalog open on
Flitslig) quit within a second of the ask; force unmount succeeded at once; power back at 2 min 18 s;
remount at once and the SMB share with it. Readings during it: 100 % / 66 min at transfer, 78 % /
50 min at 1 min (92 W), 72 % / 57 min at 2 min (85 W); 72 % / 26.4 V / charging ten minutes later.
**The charge gauge is voltage-derived**: it loses 20–30 points in the first minute under load and
then flattens; the runtime estimate tracks the load and is the better guide. Do not "fix" the
gauge in software; show the voltage beside it (the chart hover and the progress log lines do).
The self-test was also run live: 11 s, passed, line-present flag stayed set.

## Not verified (as of 2026-10-10)

- The drill (real unmounts under a pretend outage) and the manual *Unmount Now*. Each is one menu
  click for the owner.
- Where the charge gauge settles after the first minutes on battery: the one real outage lasted
  2 min 18 s. A ten-minute plug-pull with nothing mounted would show the curve.
- `PowerActions.shutDown()` (the `aevtshut` event to loginwindow) and `sleep()` (`IOPMSleepSystem`).
- Agent registration from `/Applications` and the enable/disable hand-over between copies.
- What happens when the owner is accessing the volume over SMB from another machine during the
  outage: `smbd` is a daemon, so it is never asked and the force unmount cuts the client off at the
  hard limit. That is the intended behaviour; it has not been watched from the client side.

## Release and distribution

Same as the siblings: `VERSION=` in `build.sh`, `CFBundleVersion` = commit count,
`./build.sh release NOTES.md` builds the stapled app, the DMG and the updater's zip, tags
`v<VERSION>`, runs the preflight and publishes. Signing reads `SIGN_IDENTITY` / `NOTARY_PROFILE`
from the git-ignored `.signing` (copy it from a sibling). The GitHub repository
`njoubert/nimbus-ups-bar` did not exist on 2026-10-10; CI's `update-health` job is
`continue-on-error` until the first release carries `NimbusUpsBar-<version>.zip`, then drop
that line. No `docs/screenshot.png` or social card yet: take the screenshot by hand once the
menu is final (open it, ⇧⌘4, space, click it) and port `SocialCard.swift` from a sibling.
