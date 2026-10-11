<p align="center">
  <img src="docs/icon.png" alt="Nimbus UPS Bar icon" width="128">
</p>

<h1 align="center">Nimbus UPS Bar</h1>

<p align="center">
  A macOS menu bar guard for a desk on a UPS: when the mains fail it watches the UPS, gives the
  apps a chance to close, and cleanly unmounts the external drives before the battery runs out.
  Everything the UPS reports, a chart of load and charge, and a health check, in the dropdown.<br>
  No Dock icon, no window. Swift, SwiftPM, AppKit. One dependency: our own
  <a href="https://github.com/njoubert/nimbus-updater">nimbus-updater</a>, which keeps it up to date.
</p>

```
./build.sh run            # debug build → dist/debug/Nimbus UPS Bar.app, launch it (add --fg for logs here)
./build.sh stop           # quit it
./build.sh test           # the outage state machine against fakes (swift test)
./build.sh install        # release build → /Applications/Nimbus UPS Bar.app, register its launchd agent, launch
./build.sh uninstall      # unregister the agent, remove the app and its preferences
./build.sh status         # running? installed? agent registered?
./build.sh app            # release build → dist/Nimbus UPS Bar.app only
./build.sh dmg            # release build → dist/NimbusUpsBar-<version>.dmg, drag-to-Applications disk image
./build.sh icon           # re-render docs/icon.png
```

## Why it exists

A MacBook Pro used as a desktop, lid closed, with a Studio Display and an OWC enclosure holding a
four-drive NVMe RAID, all on a CyberPower UPS. When the mains fail, the laptop survives on its own
battery; the enclosure dies the moment the UPS runs out, with whatever was in flight on the RAID.
macOS cannot help: its UPS shutdown thresholds (`pmset -u haltlevel …`) are ignored on any Mac with
an internal battery, by design. So this app does the one job: get the external volumes unmounted,
cleanly, before the UPS dies, and put them back when the power returns. The investigation behind it
is in a handoff folder the owner keeps outside the repository.

## What it does

**In the bar.** A bolt on line power, coloured by the health check: green when the UPS is ready,
yellow when something wants a look, red with a warning badge for a fault, a red struck-out bolt
when no UPS is connected (add the load in watts with *Show Load in Menu Bar*). During an outage
the icon turns orange with the UPS charge and a countdown to the next step, red while forcing,
green with a shield once the drives are safe, blue while remounting.

**The stages**, timed from the first reading on battery:

| Stage | When | What happens |
|---|---|---|
| **On battery** | Transfer | A notification with charge and runtime. The Mac is held awake (the "UPS Power" power profile would sleep it after a minute). Nothing is touched: a flicker of under the grace period only produces this. Power that comes back has to stay back for 30 s before the outage is over (the headline counts it down); under a brownout that transfers every few seconds the clock and the limits keep running, judged against the last reading on battery. |
| **Closing apps** | Grace period over (default 2 min) | Every app with files open on a protected volume is sent a quit event, the same thing as its Quit menu, so it saves or shows its own unsaved-changes dialog. Daemons (`smbd`, Spotlight, Backblaze) are left alone. As soon as no app holds a volume, that volume is unmounted. |
| **Unmounting** | Hard limit: default 5 min on battery, or charge at or below 50 %, or runtime at or below 10 min, or the UPS missing for 10 s (a USB re-enumeration drops it for a moment; that is not the battery dying), or *Unmount Now* | Every protected volume is force-unmounted whether or not an app still holds it. Force only overrides dissenters and open files; the filesystem is flushed completely either way. A volume that still refuses is retried every 10 s, and you are told once. |
| **Drives safe** | Everything unmounted | The sleep hold is released. Optionally the Mac is put to sleep or shut down. |
| **Remounting** | Power back | Whatever the guard unmounted is mounted again, if the disk is still attached. If the enclosure rebooted, macOS mounts it itself and the guard notices. |

While an outage runs, the top of the menu offers **Unmount Now**, **Postpone 5 Minutes** (the
charge and runtime limits still apply: postponing cannot talk the battery into lasting longer) and
**Don't Quit Apps This Outage**. Readings in the first 15 s on battery are ignored, because some
UPSes report 0 % for a moment at the transfer. A relaunch mid-outage (a crash restart by the
agent, an update, toggling *Run in Background*) carries the outage's clock on rather than
starting the grace period again.

**In the dropdown.** First the headline: the stage, what comes next and when, and three figures:
charge, load in watts, runtime (the UPS's own estimate at the current load). Top right, how old
those figures are and how often they are read: every 10 s on line power, every 2 s on battery and
while the menu is open (the line/battery state itself arrives from macOS the moment it changes). Then a chart of the
**last hour** in two panels on one time axis, load above and battery charge below, with minutes on
battery tinted; hover for the values at any moment. Then:

- **Protected Volumes**: every external volume, with a dot (green mounted, yellow unmounted or
  being worked on, red detached) and who has files open on it. Each has a submenu with *Unmount
  Now* / *Mount*, its UUID, device, mount point, drive model, and the processes holding it.
- **UPS Health**: the checks below, each with a dot, and *Run Battery Self-Test…*, the UPS's own
  ten-second quick test.
- **UPS Details**: every field the UPS reports over USB HID, grouped by battery, input and output,
  plus the entry macOS keeps for it (`pmset -g ps`) and the Mac's own battery. Click any row to copy.
- **Simulate an Outage**: a **rehearsal** (a pretend outage at 10× speed against the real volumes
  and the real apps holding them; it logs what it would do and touches nothing) and a **drill** (the
  same pretend outage at 5× with real quits, real unmounts and real remounts; it never sleeps or
  shuts down the Mac, and a real outage abandons it).
- **Outage Policy**: the grace period, the three hard limits, whether apps are asked to quit, and
  what to do once the drives are safe (keep running, sleep, shut down).
- **Volumes to Protect**: all external volumes (the default), or only the ones you check. Disk
  images and the EFI and boot helper partitions never count as external.
- **Recent Events** and *Open Log File*: every decision, reading and action, timestamped, in
  `~/Library/Logs/Nimbus UPS Bar/ups-bar.log` (also in the unified log under
  `com.njoubert.nimbusupsbar`).
- **Run in Background at Login**, **Notifications**, **Show Load in Menu Bar**, the update items,
  the version, Quit.

**Health.** The health row and the headline name the first thing that is wrong, not just that
something is. Red: no UPS on USB, the replace-battery flag, an overload, a failed self-test,
shutdown imminent. Yellow: on battery, charge below the UPS's warning limit on line power, battery
voltage at or below nominal while not charging (a worn pack floats low), load at 0 % (nothing is
on the battery outlets?) or above 80 %, line voltage outside or near the edge of the transfer
window, boost or buck active, no USB reading for a minute. Hollow grey notes that colour nothing:
recharging after an outage, self-test not run yet. Green otherwise, with the figures.

**Persistence.** *Run in Background at Login* registers a per-user launchd agent from the app
bundle (System Settings › General › Login Items › Allow in the Background). It starts the app at
login and restarts it if it ever crashes; a deliberate Quit stays quit. The first launch from
`/Applications` registers it once; turning it off afterwards sticks. Only one copy ever runs: a
second copy asks the first to quit and takes over.

**Updates.** Through [nimbus-updater](https://github.com/njoubert/nimbus-updater), as in the
sibling apps: once a day, and when the menu opens if the last check is stale, it asks GitHub for a
newer release, downloads it in the background, and the menu offers **Install Update and Relaunch**.
A download is installed only if macOS confirms it is signed by the same Developer ID as the
running copy. *Check for Updates Automatically* turns the daily check off, and with it off the app
never contacts anything: `api.github.com` and `release-assets.githubusercontent.com` are the only
hosts it ever talks to.

## Setting up

1. **Install it**: `./build.sh install`, or drag the app from the disk image to `/Applications`
   and open it once. It registers its background agent and asks to show notifications.
2. **Check the health line.** Open the menu: the headline should name your UPS, the health line
   should be green, and the load should be the watts your desk draws. A load of 0 % means the
   things you care about are plugged into the UPS's surge-only outlets, which the battery does not
   back.
3. **Choose the volumes.** *All External Volumes* is right for a desk where everything external is
   on the UPS. Otherwise check the ones that are.
4. **Set the policy.** The defaults (2 min grace, 5 min / 50 % / 10 min hard limits, ask apps to
   quit, keep running afterwards) suit a UPS with an hour or more of runtime. With a heavy load and
   a short runtime, shorten the grace period.
5. **Rehearse.** *Simulate an Outage › Rehearse*: watch the menu and the log walk through the
   stages in about half a minute without touching anything.
6. **Drill**, with your work saved: the same with real unmounts. The volumes come back by
   themselves at the end.
7. **Pull the plug.** The real test, done at the keyboard with the log open and nothing important
   open on the drives: pull the UPS's wall plug, see the transfer within seconds, plug it back in
   inside a minute and see nothing unmounted; pull it again and wait for the unmount; plug it back
   in and see the remount.

## How it works

- `Sources/UpsGuardCore/` is the state machine with no AppKit and no IOKit: the readings, the
  policy, the phases, the rehearsal and drill wrappers, the simulated UPS. `swift test` drives it
  through 27 scenarios with a fake clock, fake volumes, fake holders and fake actions.
- `Sources/NimbusUpsBarKit/` is the platform layer, a library so its logic can be tested
  without a UPS. `PowerSources.swift` reads macOS's own power-source entries
  (`IOPSCopyPowerSourcesInfo`, what `pmset -g ps` prints) and gets a run-loop notification the
  moment the UPS state changes.
- `UPSHID.swift` reads the UPS over USB HID directly, which is where the load, the input, output and
  battery voltages, the UPS's own low-battery limits, the self-test result and the flags live. A full
  read of every element takes about 30 ms. The one write it ever makes is the self-test start.
- `Volumes.swift` keeps the external volumes current through Disk Arbitration and does the unmount
  (force) and mount through it; no `diskutil`. Volumes are identified by their volume UUID, never
  by `diskN`.
- `Holders.swift` finds the processes with files open on a volume with `proc_listpidspath` (what
  `lsof` uses), in about 60 ms, and asks an app to quit through `NSRunningApplication.terminate`,
  a quit Apple event, addressed to the owning app's bundle id so that a helper process (a browser
  renderer) gets its parent asked. Executables under `/System` are never apps to it.
- `Sources/NimbusUpsBar/Monitor.swift` ties it together on a 2 s timer (HID every 10 s on line power, every 2 s on
  battery), keeps the chart's samples, and runs simulations.
- `swift test` runs 41 outage scenarios against a fake desk (flapping mains, a UPS that drops off
  USB for a moment, a relaunch mid-outage, a volume that refuses to unmount, two volumes landing
  at different times, …) and 45 checks of the platform layer against fixtures, among them a raw
  dump of the CP1500's 58 HID elements, so the decode, the health rules and the volume filter are
  checked in CI with no hardware attached.

The command line has the same readers and the same guard with no UI:

```
.build/debug/NimbusUpsBar --print          everything the menu would show, as text
.build/debug/NimbusUpsBar --print-menu     the menu itself, built against the real UPS, as a tree
.build/debug/NimbusUpsBar --watch          readings and the guard's log as they happen
.build/debug/NimbusUpsBar --simulate       a rehearsal in the terminal
.build/debug/NimbusUpsBar --holders /Volumes/Flitslig
.build/debug/NimbusUpsBar --volumes
.build/debug/NimbusUpsBar --dump-hid-raw cp1500.json   every raw HID element value, as the decode's fixture
.build/debug/NimbusUpsBar --after-safe sleep           the after-safe action, once, after a typed confirmation
```

## Platform facts it rests on

Checked on macOS 27 with a CyberPower CP1500PFCLCDa.

- macOS ignores UPS shutdown thresholds on any Mac with an internal battery (`man pmset`, and the
  check in Apple's `pmconfigd/UPSLowPower.c`).
- The UPS is a USB HID Power Device handled by `ioupsd`; a second, shared open from this app is
  allowed. CyberPower reports battery volts in tenths once the figure has two digits (271 for
  27.1 V), the quirk NUT corrects for; the self-test result uses NUT's mapping (6 = not run).
- A plain unmount of a volume with an SMB share point on it is always dissented by `smbd`, even
  with no client connected. Force overrides that and still flushes. After a remount the share comes
  back on its own.
- A quit Apple event to an app needs no Automation permission (required-suite events are exempt).
- The "UPS Power" pmset profile sleeps the Mac a minute after the transfer; a
  `PreventUserIdleSystemSleep` assertion holds it awake until the unmount is done.
- When the UPS finally dies, the closed-lid laptop goes to sleep on its own battery (adapter and
  display both vanish). Nothing to do about that, and nothing is at risk by then.

## What a real outage looked like

Plug pulled on 2026-10-10 at 18:25 with Lightroom Classic holding Flitslig, load about 100 W:
transfer seen within seconds; at 2 min 02 s Lightroom was asked to quit and let go within a
second; Flitslig unmounted at 2 min 03 s; power back at 2 min 18 s and Flitslig remounted at once.

The charge gauge went 100 % → 78 % after one minute → 72 % after two, while the runtime estimate
stayed near an hour (66 → 50 → 57 min, following the load). (The guard has since learned to wait
30 s of steady mains before standing down, so today the remount would have come at 2 min 48 s.)
The gauge is not an energy count: on
this UPS it follows the battery voltage, which sags 20–30 % worth in the first minute under load
and then flattens, and climbs back only as the charger brings the voltage up over the following
hours. A hard limit at 50 % therefore fires earlier than "half the energy" suggests, which is the
safe direction; the runtime estimate and the time on battery are the better guides to how long
the drives really have. To see where the gauge settles under your load, pull the plug once with
nothing mounted and watch the chart for ten minutes.

## Before relying on it unattended

The tests cover the decisions; these are the things only the desk can show. Each is a few minutes
at the keyboard, with nothing important open on the drives.

1. **Rehearse, then drill** (*Simulate an Outage*). The drill really unmounts and remounts.
2. **Pull the plug** with the log open: transfer within seconds, the stages at the times the
   policy says, the remount 30 s after power returns.
3. **Pull the USB cable** 30 s into a plug-pull: the headline says "UPS not answering" and nothing
   is unmounted; leave it out and after 10 s everything is, as if the battery had died.
4. **Flap it**: plug the wall lead back in for 10 s during a plug-pull, then pull it again. One
   "Power outage" notification, no "Power restored", the clock keeps counting.
5. **A browser holding a file on the drive** during a drill (a download in progress, a file open
   from it): the browser itself is asked to quit, not one of its helper processes.
6. ***Unmount Now*** from the menu during a drill.
7. **The after-safe action.** `--after-safe sleep` and `--after-safe shutdown` from a terminal,
   each once: both ask for a typed confirmation. For shutdown, watch whether macOS puts up an
   Automation prompt for `loginwindow` the first time; if it does, approve it, because unattended
   that prompt would be a silent no-op. Neither has been run on this desk yet.
8. **The agent.** After `./build.sh install`: `kill -9` the running copy and see it back within
   10 s; toggle *Run in Background* off and on, with `pgrep -x NimbusUpsBar` showing one pid each
   time; `./build.sh run` while the agent is enabled (it quits the agent copy cleanly, and the
   dev copy stays).
9. **Launch during an outage** (`./build.sh run` with the plug pulled): the clock resumes from the
   previous copy's start.
10. **The SMB client side** during a forced unmount, and a ten-minute plug-pull with nothing
    mounted to see where the charge gauge settles.

Not covered by anything: a Mac that is already asleep when the outage starts does not run the
guard (on line power this desk never sleeps, so the gap is only a manual sleep), and phase 2,
email notifications for when the desk is unattended, is designed in
`docs/phase-2-email-notifications.md` and not built.

## Licence

GPL-3.0-or-later. Copyright (C) 2026 Niels Joubert.
