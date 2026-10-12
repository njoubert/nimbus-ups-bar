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
  outage paths run without an outage. Likewise a change to `Health`, `UPSHID.decode`,
  `VolumeRegistry.state(from:)`, `Holders.describe`, `ReadingMerge`, `HIDReadGate`,
  `CarryoverStore`, `LaunchdJob.startFailure` or `DevDefaults` without a fixture test in
  `Tests/NimbusUpsBarKitTests/` is not finished: those are the rules that misfire on an input
  nobody tried. The committed HID dumps are the decode's reference: `cp1500pfclcda.json` (2026-10-10,
  values only) and `cp1500pfclcda-full.json` (2026-10-11, `--dump-hid-raw`'s full capture: every
  element with its metadata, the collections, every report's bytes, the descriptor, the device's
  properties). A second UPS model is a second fixture, not a second desk.
- **Licence headers.** Every new Swift file starts with `// Copyright (C) 2026 Niels Joubert` /
  `// SPDX-License-Identifier: GPL-3.0-or-later`. GPL-3.0-or-later; don't vendor incompatible code.
- **It talks to nothing but GitHub, and only for updates.** `api.github.com` plus
  `release-assets.githubusercontent.com` unless *Check for Updates Automatically* is off. README
  must keep saying exactly this.
- **Resolve volumes by UUID**, never by `diskN` (those get reused) or by name alone.

## Workflow

- **Changes go up as pull requests.** Branch from `main`, commit there, push, `gh pr create`
  against `main`; the owner reviews and says when to merge. Do not commit or push to `main`
  directly unless the owner explicitly says to commit straight to `main` for that change; an
  earlier instruction to do so does not carry over to the next change. Landing a PR (merge,
  delete the branch) is also the owner's call.
- **Check that a push arrived before relying on it.** Compare `git rev-parse HEAD` with
  `git ls-remote origin refs/heads/<branch>` after every push, and the PR's `headRefOid` with
  the local commit before merging; never filter a push's output away. On 2026-10-11 three
  commits of PR #8 never reached GitHub, the PR merged without them, and PR #9 had to restore
  them.
- **A PR that touches anything the owner sees gets a screenshot in its description**: the menu,
  the headline, the chart, the Settings window, notifications, the icon, the DMG. Show the
  state the change is about (hovered, empty, light and dark where it matters), before and after
  when it changes something existing. Render with the dump flags rather than asking for a
  screen: `--dump-chart`, `--dump-settings`, `--dump-inspector`, `--dump-bar`, `--render-dmg-background`; for what
  they do not cover (the open menu as a whole), ask the owner for one.
- **Where the images live:** `gh` cannot upload images into a PR body, so they go on the orphan
  branch `pr-assets` (never merged; screenshots and the repo's `.pre-commit-config.yaml`, so its
  commits pass the hooks like any other), under `pr-<number>/`. Push them with a worktree so the
  working branch is not disturbed (`git worktree add <scratch dir> pr-assets`, copy, commit, push,
  `git worktree remove`), then link them by the commit's SHA:
  `https://raw.githubusercontent.com/njoubert/nimbus-ups-bar/<sha>/pr-<number>/<file>.png` (the
  repo is public, so they render). Not by the branch name: raw.githubusercontent caches a 404 for
  minutes, and a SHA link never changes under the PR. Add the images after `gh pr create` gives
  the number, then `gh pr edit <n> --body-file …`.

## Layout

```
Sources/UpsGuardCore/        the library the tests drive; no AppKit, no IOKit
  Readings.swift             UPSReading (+ flags, self-test), VolumeState, Holder, GuardError
  Policy.swift               Trigger (time / runtime / charge, whichever first); the policy: three
                             stages, the power-down action, the UPS-gone choices; never-quit list
  Environment.swift          GuardEnvironment protocol; RehearsalEnvironment (touches nothing,
                             scaled clock, pretends asked apps quit); DrillEnvironment (real
                             actions, scaled clock, never sleeps/shuts down)
  Guard.swift                OutageGuard: the phases, the limits, the owner actions, Status;
                             Duration formatting
  Simulation.swift           SimulatedOutage: a pretend UPS draining at N× that dies at 0, in four
                             scenarios (drain, shortBattery, upsLostInOutage, upsLostOnLine);
                             advance() decides when the pretend power comes back
Sources/NimbusUpsBarKit/     the platform layer, a library so it is testable (AppKit and IOKit
                             allowed; no UI, no Log, no Settings)
  PowerSources.swift         IOPSCopyPowerSourcesInfo + the change notification; monotonicNow()
  UPSHID.swift               the UPS over USB HID: fetch() → RawReport (the routine read, the 58
                             elements the decode uses, ~30 ms) or fetch(full: true) (every
                             element, report, the descriptor and properties, ~100 ms; the
                             Inspector and --dump-hid-raw); decode(_:now:) → Report (pure; the
                             quirks); the self-test write
  Volumes.swift              VolumeRegistry: Disk Arbitration callbacks, state(from:) (pure
                             external filter), force unmount, mount
  Holders.swift              proc_listpidspath → Holder; describe (an app = LaunchServices knows
                             it, with a UI, or it is such an app's helper); quit by bundle id;
                             ProcessWorld: the LaunchServices/libproc seam the tests fake
  HIDReader.swift            HIDReadGate (pure): when a read starts, is written off (10 s), when
                             a fresh device object is opened; HIDReader runs each read on its own
                             thread
  CarryoverStore.swift       the guard's Carryover in UserDefaults, 12 h staleness (pure)
  DevDefaults.swift          the dev bundle's first-run copy of the release's settings, never
                             the outage state (pure)
  Health.swift               the health rules → [Item] with a level (pure)
  Merge.swift                ReadingMerge: IOKit's entry + a fresh HID report → one reading (pure)
  Inspector.swift            the Inspector's data: Section/Row, the UPS / power source / health /
                             guard / volumes sections, JSON (sorted, pretty), the change diff, the
                             page search (substring match, heading-aware filter, JSON ranges) (pure)
  Launchd.swift              `launchctl print gui/<uid>/<label>`, its parser, and startFailure
                             (launchd's last spawn failed: the health warning)
  LogEvent.swift             a log line's kind (outage, stage, apps, volume, …) for Events (pure)
Sources/NimbusUpsBar/        the app
  main.swift                 flags, AppDelegate, single-instance rule, agent toggling
  CLI.swift                  --print / --print-menu / --watch / --simulate / --holders / --volumes
                             / --check-update / --preflight / --agent-plist / --dump-hid-raw
                             / --after-safe
  Monitor.swift              UPSMonitor: timers, the merge, samples for the chart, simulations,
                             outage persistence (outageStartedAt + the guard's carryover, saved
                             on every guard change), the arming delay, the App Nap activity;
                             RealEnvironment (the live GuardEnvironment)
  Settings.swift             UserDefaults: policy (each stage's three conditions as value + on/off
                             flag, "hardRuntime" + "hardRuntimeOn"; migrateLegacyPolicy() copies
                             the pre-2026-10-11 grace/hard/afterSafe keys over once, keeping them),
                             read intervals, chart span, volume mode and selection, known volumes;
                             every setter posts Settings.didChange
  InspectorModel.swift       the Inspector's sections from the monitor, plus readings and agent;
                             the change log, the flash stamps, the whole snapshot as JSON
  InspectorWindow.swift      the Inspector window: sidebar, Table/JSON, search, Copy Page, flash rows
  SettingsWindow.swift       the Settings window: NSTabViewController with toolbar tabs, the four
                             panes, Form/Controls helpers, DurationFormatter, the main menu
  Log.swift                  the log file (the Inspector's Events reads its tail), a 1000-line ring, os_log
  Notifications.swift        UNUserNotificationCenter (bundle only); whether macOS allows them
  BackgroundAgent.swift      SMAppService.agent + the plist text build.sh bakes in
  PowerActions.swift         sleep assertion, IOPMSleepSystem, the loginwindow shutdown event
  StatusBarController.swift  the bar, the menu, every submenu (UPS Details moved to the Inspector),
                             menuText() for --print-menu
  HeadlineView.swift         the phase + three figures at the top of the menu
  ChartView.swift            load and charge, two panels, time ticks, newest values in the headers,
                             the charge limit, outage bands, hover readout
  AppIcon.swift, DMGBackground.swift, Updates.swift   as in the siblings
Tests/UpsGuardCoreTests/     97 scenarios against FakeEnvironment, each rehearsal scenario among them
Tests/NimbusUpsBarKitTests/  99 checks: the HID decode against both CP1500 fixtures and
                             hand-made maps, every health rule (and that each menu row fits), the
                             DA dictionary filter, the holder resolver against a fake desk (and
                             no AppleScript in it), the merge, the Inspector's sections, JSON,
                             diff and search, the launchctl parser and the 2026-10-11 failed
                             login, the log-line kinds, the stuck-read recovery on real threads,
                             the relaunch carryover store, the dev bundle's settings copy
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
./build.sh run [--fg]         debug build as dist/debug/Nimbus UPS Bar Dev.app (quits any running copy first)
./build.sh test               swift test: the 97 guard scenarios and the 99 platform checks
./build.sh install            release → /Applications, register the agent (owner's call), launch
.build/debug/NimbusUpsBar --print        the UPS, health, every HID field, volumes, holders, policy
.build/debug/NimbusUpsBar --print-menu   the menu built against the real UPS, as an indented tree
.build/debug/NimbusUpsBar --inspect-json the Inspector's snapshot (every section as JSON); the guard
                                         is never armed in it, and its Guard section says so
.build/debug/NimbusUpsBar --dump-inspector D   the Inspector on screen, each section → D/N-id.png
                                         (and N-id-json.png): its layout check
.build/debug/NimbusUpsBar --watch        readings + the guard's log as they happen (Ctrl-C)
.build/debug/NimbusUpsBar --simulate [S] a rehearsal in the terminal (~30 s; touches nothing); S is
                                         drain (default), shortBattery, upsLostInOutage, upsLostOnLine
.build/debug/NimbusUpsBar --dump-chart P the chart with fake data at menu width → P, P-hover, P-light, P-empty
.build/debug/NimbusUpsBar --dump-settings D   each Settings pane → D/N-name.png, then the real window
                                         on screen for ~3 s → D/window-N-name.png (the layout check)
.build/debug/NimbusUpsBar --dump-hid-raw P   the full HID capture as JSON: the decode's fixture
.build/debug/NimbusUpsBar --after-safe sleep|shutdown   the power-down action once, at a TTY, after typing it
```

`--print-menu` is the way to check the menu without a screen: it calls the same `rebuild()` an
open does, so a crash in a submenu shows up there. The accessibility route the siblings use
(`osascript … System Events`) needs Assistive Access for the terminal, which this machine's
terminal does not have as of 2026-10-10.

**Which copy is running matters.** The bare `.build/debug` binary has no bundle: no agent plist
(`Run in Background` is disabled, `--agent-status` says so), no notifications, and
`UserDefaults` land in a `NimbusUpsBar` domain rather than `com.njoubert.nimbusupsbar`. Test
behaviour through the bundle `build.sh run` makes. That bundle is *Nimbus UPS Bar Dev*,
`com.njoubert.nimbusupsbar.dev` (`Updates.devBundleID`): its own defaults domain (seeded once
from the release's by `DevDefaults`, outage state left behind), notification permission, agent
label and Login Items entry. It still quits the installed copy at launch (one guard at a time),
which then stays down until the next login or a hand launch. Never run a binary with the
release's identifier from anywhere but `/Applications` (see Platform facts).

## How the guard decides (read Guard.swift for the details)

Every acting stage begins on a `Trigger` (`Policy.softAt`, `hardAt`, `powerDownAt`): on battery
≥ T, runtime ≤ R, charge ≤ C, each optional, **whichever comes first** (`Trigger.reasons`). Charge
and runtime count only from readings taken after `ignoreReadingsSeconds` (15 s), however long the
clock then runs; postponing moves every time condition and no other. `softAt` may be `never` (the stage is skipped); `hardAt` may not (`normalized` puts
the 5 min back). Phases from the first reading on battery: `holding` (nothing touched) → `soft`
(apps holding files are sent one quit each; a volume unmounts as soon as no app outside the
never-quit list holds it, or, with `quitTimeoutSeconds` set, once every app holding it was asked
that long ago; once begun the stage stays begun) → `hard` (`hardAt`, the UPS gone under
`upsGoneInOutage = .forceUnmount`, the UPS's own alarms (shutdown imminent, `belowCapacityLimit`,
`runtimeLimitExpired`), *Unmount Now*, a pending power-down, or `Policy.hardStandIn` (5 min) when
`hardAt` has no time condition and the UPS reports none of the figures it needs: force-unmount
everything; once begun the stage stays begun too, `hardBecause` keeping its reason) → `safe`
(sleep hold released) → on line power `restoring` (remount what *we* unmounted, retrying every
30 s while the disk is attached; a macOS auto-remount counts).
**Power down** (sleep or shut down, `powerDownAction`) is its own stage: `powerDownAt`, or the UPS
gone with `upsGoneInOutagePowersDown`, sets `powerSince`, which adds "about to …" to the hard
reasons; the action runs once safe. A shutdown also runs `powerDownWait` (60 s) later regardless
(macOS unmounts on the way down); a sleep never runs with a protected volume mounted, because the
volume would still be mounted when the UPS dies: the guard stays awake, retries, and logs it once. With
`powerDownWhenSafe` it also runs on reaching safe, but only once an unmount stage was due, so a
blip with nothing mounted cannot sleep the Mac. Never while standing down, never in a drill, once
per outage. **The UPS gone on line power** (`upsGoneOnLine`, only once a UPS has been seen):
`.notify` notifies once per loss; `.unmount` starts a *blind* outage (`Status.blind`) that forces
the volumes at once, never powers down, and ends like any other once the UPS is back on line power
(a reading on battery turns it into a real outage). Everything is force: `smbd` dissents a plain
unmount of any volume with a share point on it; force still flushes.

The debounces, all found by the 2026-10-10 review: **line power must stay back for
`Policy.lineStableSeconds` (30 s)** before `endOutage`; until then the outage continues, the
limits are judged against the last reading on battery, and the headline counts down. A brownout
that transfers every few seconds therefore reaches the limits instead of resetting them. While
standing down no time condition counts (`Trigger.reasons(countTime:)`, the quit timeout and the
stand-in too): a stage that falls due then begins only if the power fails again; charge, runtime
and the UPS's alarms still count (found by the 2026-10-11 QA: mains back at 1:55 still asked
Lightroom to quit at 2:00). **The
UPS must be absent for `Policy.upsGoneSeconds` (10 s)** before it counts as gone; a one-tick
absence is a USB re-enumeration. **The sleep hold is evaluated every tick** from whether anything
is mounted, so a volume that appears mid-outage (or after a relaunch, when Disk Arbitration's
replay lands after the first tick) gets it. **A failed unmount backs off `unmountRetry` (10 s)**
and notifies once per volume; a volume still reported mounted within 10 s of a successful unmount
is left alone (Disk Arbitration's description change can trail the completion). **`resume`**
lets the app carry an outage across a relaunch: the monitor keeps `outageStartedAt` (wall clock)
in UserDefaults while an outage runs, and the guard's `carryover` under `guardCarryover` on every
guard change: the volumes it unmounted and has not remounted, and for the outage the apps asked
(with when), the owner's Postpone, Don't Quit Apps and Unmount Now, and whether the Mac was
already put down. At launch both go to the guard. A first reading on battery resumes the outage;
a first reading on line power resumes it into a fresh 30 s stand-down (the previous copy may have
died mid-stand-down; remounting at once would hand a brownout a free remount); either way the
outage's own state comes back. Remounts need a UPS seen on line power, so a blind outage carried
across a relaunch does not remount with nothing watching. The first armed tick that finds no
outage drops a leftover `outageStartedAt`; both keys are dropped after 12 h. (Found by a review
of the QA fixes, 2026-10-11.) The monitor also does not tick the live guard for `armDelay` (3 s) after start,
so the first look is at the real desk, not an empty one.

A completion (unmount/mount) that lands mid-tick sets `retick` and the tick runs once more at
the end, so `safe` is reached the moment the last volume lands rather than two seconds later;
`maxRounds` (4) caps it, and a scenario re-enters the guard from inside to prove the cap holds.

## Platform facts (checked 2026-10-10 on this desk)

- **macOS ignores UPS shutdown thresholds on laptops** (`man pmset`; `pmconfigd/UPSLowPower.c`).
- **`IOPSCopyPowerSourcesInfo` lists the UPS** with `Type = UPS`, `Power Source State`, `Current
  Capacity`, `Time to Empty` (minutes; 0 = no estimate), `Voltage` (mV). `IOPSNotificationCreateRunLoopSource`
  fires on changes; it is scheduled in `.commonModes` so it fires with the menu open.
- **The IOKit entry's `Voltage` key is not the line voltage.** `ioupsd` writes whichever voltage
  element it read last: 122000 mV at one read, 27100 (the battery) a minute later. The app ignores
  it (it still shows in the Inspector › Power Source) and takes every voltage from HID.
- **The HID report is the richer source**, read through `IOHIDManager` with a shared open
  (`ioupsd` keeps its own). The CP1500PFCLCDa's descriptor (726 bytes) declares 158 elements in
  10 collections: 58 feature, 12 input-misc, 10 input-button, 2 output, 76 input-null padding.
  Every input value also exists as a feature (the battery flags in input report 11 and feature
  report 11; the charge in input report 8); macOS lists the input copy first. The two vendor
  output elements (0xFF01/0x15, 0x17) and two padding elements fail to read (0xE0005000), as
  does GET_REPORT for input report 0. The decode reads the first input or feature element of
  each (enclosing collection, page, usage), 58 of them, ~30 ms; `Voltage` 0x84/0x30 exists
  under Input, Output and the battery's PowerSummary, which the key tells apart.
- **IOHIDManager reports the UPS already plugged in as an arrival** once the run loop turns
  after `IOHIDManagerOpen`, at every launch. `UPSHID` takes `IOHIDManagerCopyDevices` right after
  the open and passes `atStart` for those, so the log records only a real plug or unplug (it
  used to say "UPS attached over USB HID" at every start).
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
- **The holding process is often not the app.** A Chromium renderer or an Electron utility
  process holds the file; many such helpers are LaunchServices-registered with their own bundle
  id (`com.brave.Browser.helper`, `com.apple.controlcenter.helper`, ChatGPTHelper and iStat Menus
  Helper were all registered on this machine on 2026-10-10), so terminating by pid hits the
  helper and the parent relaunches it. `requestQuit` goes by the resolved app's bundle id first,
  pid second.
- **Being inside an `.app` does not make a process an app** (QA 2026-10-11). Homebrew's `python3`
  runs from `Python.framework/…/Python.app` and is no LaunchServices application; with
  `xcode-select` pointing into Xcode, `/usr/bin/git`, `swift`, `clang` and VS Code's
  `sourcekit-lsp` run from inside `Xcode.app`, and SourceKit's XPC service lives in Xcode's
  toolchain but is launched (ppid 1) for VS Code. LaunchServices also lists background-only
  processes (`activationPolicy == .prohibited`: `sharingd`, `studentd`, Finder extensions, Adobe's
  crash processor). So `Holders.describe`: an app is a running application with a UI, or a helper
  of one (started by it, by the ppid chain, or one of its own XPC services or extensions:
  `Contents/XPCServices/*.xpc`, `Contents/Frameworks/…/XPCServices/*.xpc`,
  `Contents/PlugIns/*.appex`). `/Library/Apple/` and `/System/` are never apps, except the
  user apps Apple ships there: `…/System/Applications/` (Preview, TextEdit, Notes; Safari runs
  from `/System/Volumes/Preboot/Cryptexes/App/System/Applications/`) and
  `CoreServices/Applications/` (Archive Utility). On this desk `--holders /` then lists only
  real UI apps and their helpers and extensions.
- **Never send an Apple event that waits, least of all on the main thread.** Compiling an
  `NSAppleScript` "tell application id …" fetches the target's terminology over an Apple event;
  a process that never answers (Homebrew `python3`) held the main thread for the full 120 s
  timeout: no ticks, no hard limit, no menu (QA 2026-10-11, H1). `NSRunningApplication.terminate`
  only sends. `HoldersTests` fails if an AppleScript or `AESend` call appears in `Holders.swift`.
  (`PowerActions.shutDown` still uses one, to loginwindow, as the last act of an outage.)
- **`proc_listpidspath` sees only this user's processes without root**: `smbd`, `mds_stores`,
  `bztransmit` and other users' processes never appear, so the menu says "None of your
  processes", never "nothing".
- **A signal is a crash to launchd.** `KeepAlive = {SuccessfulExit = false}` restarts the job
  after `pkill` (SIGTERM) ten seconds later, and the restarted copy, being newest, then quits
  whatever build.sh launched. `stop_all` sends the quit Apple event instead (exit 0, stays quit)
  and `install` unregisters the old bundle's agent before replacing it.
- **A HID read can wedge.** A stalled `IOHIDDeviceGetValueWithOptions` used to leave the
  in-flight flag set for the life of the process; then, with every read on one serial queue,
  the next read waited behind the stuck one forever (QA 2026-10-11, M4). Now `HIDReader` runs
  each read on its own thread of a concurrent queue: one overdue by 10 s is written off and the
  next starts beside it through a fresh `IOHIDDevice` for the same service (`UPSHID.reopen`:
  `IOHIDDeviceCreate`, open, its own elements), so two reads never share a device object and
  the stuck one is never closed under its thread (IOKit's user-space HID objects are not
  documented as thread-safe). Removals are matched by registry id, since the object in use may
  not be the manager's. Three stuck threads stop new reads until one returns; a late result is
  dropped by sequence. Counters in the Inspector's Readings page. Never seen against the real
  UPS since.
- **App Nap**: an idle accessory app can be napped, which coalesces the 2 s timer the guard
  ticks on. The monitor holds `beginActivity(.userInitiatedAllowingIdleSystemSleep)` from
  `start()` to `stop()` (QA 2026-10-11, M6); it does not stop idle sleep, which the guard's own
  assertion manages. The Inspector's Service & App page says whether it is held.
- **A forced unmount leaves SMB clients stale** (verified by the owner, 2026-10-11): after the
  unmount and remount, `smbd` still exports the share and the Mac Studio's TCP session stays up,
  but its mount of Flitslig is dead (Finder: "the original item for 'Flitslig' can't be found")
  until it is ejected and connected again. The remount notification says so.
- **Notifications can be blocked silently.** `requestAuthorization` answers a denial with
  `ok == false` and no error; the dev bundle was denied on 2026-10-10. `Notifications` now asks
  `getNotificationSettings` at launch and at most once a minute, logs changes, and a block is a
  yellow health item with a button in Settings › General.
- **Disk Arbitration from Swift:** `kDADiskDescriptionMatchVolumeMountable` and
  `kDADiskDescriptionWatchVolumePath` import as `Unmanaged`; `.takeUnretainedValue()` them.
  Registering an appeared callback replays every existing disk, which is the initial enumeration.
  Disk images report `DADeviceProtocol = "Virtual Interface"` and are *not* internal, so they are
  filtered by protocol; EFI and Apple_Boot helper partitions by `DAMediaContent` GUID.
- **`SMAppService.agent(plistName:)` reports a never-registered agent as `.notFound`**, not
  `.notRegistered`. Whether the plist is in the bundle is a separate file check (`isAvailable`).
  The plist text lives in `BackgroundAgent.plist(executable:label:)` and build.sh writes it into
  `Contents/Library/LaunchAgents/` with `--agent-plist <bundle id>`; `KeepAlive = {SuccessfulExit = false}` so
  Quit (exit 0) stays quit and a crash restarts.
- **Login Items follows the bundle id; launchd checks the binary** (found 2026-10-11, the
  installed v0.1.0 never started at login). `backgroundtaskmanagementd` keeps one record per bundle
  identifier and moves it to whichever copy last asked about its agent (`SMAppService.status`;
  the log says `_bundleURLForAuditToken: updating item … URL to …`). The job also carries a launch
  constraint on the registered binary's cdhash. A dev copy under the release's identifier opened
  its menu, the record moved to `dist/debug`, and at the next login launchd ran the dev binary:
  `OS_REASON_CODESIGNING | Launch Constraint Violation`, then `invalidateLaunchItem`, then
  `Could not find and/or execute program … 3: No such process` every 10 s (`last exit code = 78:
  EX_CONFIG`). Rebuilt while pointing at the dev copy, the record then rejected the release binary
  too. Nothing ran; the menu, opened by hand, looked healthy. Hence the dev bundle id, and the
  health warning (`LaunchdJob.startFailure`, checked every minute). Repair: Run in Background off
  and on from the `/Applications` copy. Read it with `/usr/bin/log show` (zsh's `log` is a builtin):
  process `launchd`, `xpcproxy`, `backgroundtaskmanagementd`, message containing `nimbusupsbar`.
- **Only one copy runs.** The newest copy terminates any other of either bundle id at launch
  (`AppDelegate`, `Updates.bundleIDs`), which is what makes toggling the agent work: enabling
  makes launchd start a copy that takes over; disabling spawns `open -n` of the bundle first,
  then unregisters (launchd stops the agent's job). `--dump-bar` skips the rule so it can grab
  the bar beside the live copy.
- **`UNUserNotificationCenter` needs a bundle**; the bare binary logs instead (`Notifications.available`).
- **The Settings window is an `NSTabViewController` with `tabStyle = .toolbar`** in an
  `NSWindow(contentViewController:)`. Traps found 2026-10-10: the window's title follows the
  selected child's `title` (nil shows "Untitled"), so every pane sets one; the window takes its
  initial size from the tab view's placeholder, not the first pane, so the controller sets the
  content size from the first pane's `preferredContentSize` (each pane sets it from
  `view.fittingSize` in `viewDidLoad`); an `NSButton` checkbox with `lineBreakMode =
  .byWordWrapping` collapses to a few words wide in a grid cell. Key equivalents (⌘, ⌘W ⌘C ⌘V)
  come from `NSApp.mainMenu`, which an LSUIElement app has to build itself (`MainMenu.install()`).
  Form fields hold a `DurationFormatter`; a string `Duration.parse` rejects keeps the focus and
  shows the reason under the form. AppKit shows tooltips only while the app is active, which a
  menu bar app usually is not while its window sits on screen: both windows set
  `allowsToolTipsWhenApplicationIsInactive` (2026-10-11: the owner saw no tooltip on the Force
  unmount warning sign).
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

That log is the reference sequence for the state machine: compare any change to `Guard.swift`
against it (the stages at the times the policy says, one ask, one unmount, one remount). The one
thing it would show differently today is the remount, 30 s after the power returned rather than
at once, because of the line-stable hysteresis.

## Not verified (as of 2026-10-11)

The owner's keyboard checklist is in README.md ("Before relying on it unattended"); it is the
list of things only the desk can show, and none of it is for an agent to run. The items, with
what each settles:

- The drill (real unmounts under a pretend outage) and the manual *Unmount Now*.
- The USB cable pulled mid-outage (the 10 s absent debounce) and mains flapping (the 30 s
  line-stable hysteresis): both tested against the fake, neither against the UPS.
- A browser holding a file on the drive during a drill: the quit-by-bundle-id path.
- `PowerActions.shutDown()` (the `aevtshut` event to loginwindow) and `sleep()` (`IOPMSleepSystem`),
  now reachable through `--after-safe`, which refuses without a TTY and a typed word. Whether the
  hardened-runtime bundle gets a TCC Automation prompt for loginwindow on first use is the open
  question: unattended, that prompt would be a silent no-op shutdown.
- A start at login since the 2026-10-11 repair (registration from `/Applications` works; the
  first login failed, see Platform facts), the enable/disable hand-over, the clean-quit path in
  `build.sh` (`pgrep -x NimbusUpsBar` after each step), and a `kill -9` restart.
- A launch mid-outage: the resumed clock (`outageStartedAt`) and the carried-over volumes and
  asks (`guardCarryover`), tested only against the fake.
- App Nap (the Activity Monitor column) and the notification status of the installed bundle.
- The wedged-read recovery against the real device, and the enclosure losing power and coming
  back (Disk Arbitration's disappeared and reappeared callbacks, the auto-mount).
- Where the charge gauge settles after the first minutes on battery: the one real outage lasted
  2 min 18 s. A ten-minute plug-pull with nothing mounted would show the curve.
- (The SMB client side is now known: a client's mount goes stale; see Platform facts.)

## Keeping it solid

- Every guard change gets a scenario; every decode, health, filter or resolver change gets a
  fixture case. Write the scenario first and watch it fail against the old code: every QA
  2026-10-11 scenario was checked that way. A rule about the platform (which process is an app,
  when a read is written off) belongs behind a seam (`ProcessWorld`, `HIDReadGate`) so the
  machine it was found on becomes a fixture. CI runs both suites and smoke-runs `--print`, `--volumes`, `--print-menu` and
  `--simulate` with no UPS attached, so a crash in menu code or in the rehearsal shows up on a
  pull request, not on the first click.
- The 18:25 plug-pull log above is the reference; read a state-machine diff against it.
- Disk Arbitration, IOKit and `SMAppService` are the layers that shift between macOS releases:
  run a drill after every macOS major update and write the date here. Last drill: 2026-10-11, two
  through the QA harness (`DrillEnvironment` on Flitslig, macOS 27.0.1); none from the menu yet.

## Release and distribution

Same as the siblings: `VERSION=` in `build.sh`, `CFBundleVersion` = commit count,
`./build.sh release NOTES.md` builds the stapled app, the DMG and the updater's zip, tags
`v<VERSION>`, runs the preflight and publishes. Signing reads `SIGN_IDENTITY` / `NOTARY_PROFILE`
from the git-ignored `.signing` (copy it from a sibling). Releases: 0.1.0 on 2026-10-11 (DMG +
zip, notarized). Since then CI's `update-health` job fails a run when the published release
loses its zip or no longer matches the declared bundle id and team. The DMG step asks Finder
to lay out the window over AppleScript; the first build from a new host app (VS Code's terminal,
2026-10-11) needs Automation › Finder for it, and a prompt nobody has answered yet shows up only
as `AppleEvent timed out (-1712)` with the staging image left mounted. No `docs/screenshot.png`
or social card yet: take the screenshot by hand once the menu is final (open it, ⇧⌘4, space,
click it) and port `SocialCard.swift` from a sibling.
