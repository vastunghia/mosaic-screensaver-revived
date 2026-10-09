# Spike 4 — can the saver launch the app, and does a login item keep the Photos grant?

**Questions.** The saver only reads what the app has prepared, so the index goes stale
unless the app runs now and then. Two ways to keep it fresh, each with an open question:

1. Can a `.saver`, confined to `legacyScreenSaver`, launch the app, for a button in
   its configure sheet or when it finds no index? And does the app it launches keep
   *its own* Photos grant, or inherit someone else's?
2. Can the app run as a login item (`SMAppService.mainApp`) and still read the
   Photos library?

**Answers.** Yes to both: the saver launches the app with `NSWorkspace`, and the app,
launched that way or at login, is itself with its own Photos grant. Arguments are lost on
the way from the saver; a URL scheme carries them. At login the first PhotoKit fetch
waited 108 s for the library to open.

## Method

| file | role |
|---|---|
| `Sources/Probe.swift` | **Spike4Probe.app**, standing in for Mosaic.app: on every launch it logs its parent, arguments, launch event, login-item status and Photos status, reads one photograph for real, and quits |
| `Sources/LauncherView.swift` | **Spike4Launcher.saver**: launches the probe in the way named in `/Users/Shared/mosaic-spike4/method` (the saver can read there, spike 2) |
| `Sources/host.swift` | control: loads the saver in an ordinary process, outside the sandbox |

The probe has an identity of its own (`dev.mosaic.spike4.probe`, signed with the stable
development identity), so its Photos grant is its own, the way Mosaic's would be, and the
real app's grant is never touched.

```sh
./build.sh                                     # installs into ~/Applications and ~/Library/Screen Savers
open ~/Applications/Spike4Probe.app --args --request    # grant Photos once
# choose Spike4Launcher in System Settings → Screen Saver, then close System Settings
echo workspace > /Users/Shared/mosaic-spike4/method
open -a ScreenSaverEngine; sleep 9; osascript -e 'tell application "ScreenSaverEngine" to quit'
/usr/bin/log show --last 5m --predicate 'subsystem == "dev.mosaic.spike4"' --style compact
```

**Stop the saver with `quit`, never `killall`.** Killing `ScreenSaverEngine` leaves
`loginwindow` convinced it is still running (`SACScreenSaverIsRunning = 1`): every later
launch exits with "Screen Saver Already Running" until a real key press. `caffeinate -u`
does not dismiss it either. `legacyScreenSaver` itself outlives a run of the saver and is
reused by the next one.

## Results — launching (macOS 15.7.9, 2026-10-01)

Full-screen saver inside `legacyScreenSaver`, and the same code in the control host:

| method | control (outside) | inside the saver | parent of the app | arguments arrive | Photos grant used |
|---|:--:|:--:|---|:--:|---|
| `NSWorkspace.openApplication(at:configuration:)` | ✅ | ✅ | `launchd` | ❌ dropped | the app's own |
| `NSWorkspace.open(appURL)` | ✅ | ✅ | `launchd` | — | the app's own |
| `NSWorkspace.open(URL("spike4probe://…"))` | | ✅ | `launchd` | ✅ **in the URL** | the app's own |
| `/usr/bin/open -g -b <id> --args …` | ✅ | ✅ | `launchd` | ❌ dropped | the app's own |
| `Process` on the executable | ✅ | ✅ | the launcher | ✅ | the app's own *inside*; **the terminal's** in the control |

"The app's own" was checked by revoking the probe's grant (`tccutil reset Photos
dev.mosaic.spike4.probe`): it then reported `notDetermined` when launched from the saver,
both through `NSWorkspace` and through `Process`. With the grant in place it read a
photograph out of 54,213. In the control, a `Process` child of a terminal-launched host
read the library on the terminal's grant: the TCC trap of spike 2, again.

### 1. The saver can launch the app, and the app is itself

No sandbox denial, no prompt, `activates = false` honoured. The app is a child of
`launchd`, with its own TCC identity and grant, exactly as if the user had opened it.

### 2. Arguments do not survive; a URL does

`OpenConfiguration.arguments` and `open --args` arrive empty when the caller is the saver
(they arrive in the control). A URL scheme carries the data instead:
`spike4probe://from-saver?reason=index-missing` reached the probe intact, as a `GURL`
Apple event before `applicationDidFinishLaunching`. That is the channel for "the saver
launched you, and why".

`Process` keeps the arguments, but makes the app a child of `legacyScreenSaver`: it lives
and dies with the saver's process. Not a way to launch an app that has to keep working.

## Results — login item

`SMAppService.mainApp.register()` from the probe: status `enabled` at once, no approval
asked. Then a shutdown and a cold boot:

```
22:12:46.747  open-application event: event aevt/oapp, property lgit, login item true
22:12:46.748  launched pid 675, parent 1 /sbin/launchd, arguments [], default launch 1
22:12:46.755  login item status enabled
22:12:46.762  Photos access authorized
22:14:37.532  54213 images, first read as 270×180
```

### 3. A login item is the app itself, grant included

Launched at login it is a child of `launchd` with its own TCC identity: `authorized`,
no prompt, and a real photograph read. It knows it was launched at login: the
open-application event carries `keyAEPropData` = `lgit` (read it in an `oapp` handler
installed in `applicationWillFinishLaunching`; `NSAppleEventManager.currentAppleEvent` is
already nil by `applicationDidFinishLaunching`). That is how the app decides to stay
windowless.

### 4. At login the library takes two minutes to open

The grant answers in 7 ms, but the first fetch waited 108 s in
`openPhotoLibraryDatabase`: `photolibraryd` was opening the 54,213-photo library store for
the first time since boot (internal SSD, so not a slow volume). Launched again by hand
three minutes later, the same fetch and read took 0.2 s. One cold boot measured, so
the number is an order of magnitude, not a constant.

## What changes in the plan

- **Keeping the index fresh is the app's job, as a login item.** Mosaic.app registers
  itself with `SMAppService.mainApp` (a choice in its settings, not silent), and when
  launched with `lgit` it runs windowless: an incremental index pass, then
  `PHPhotoLibraryChangeObserver` while it stays open. No helper with its own bundle id:
  it would need its own grant.
- **Nothing at login may wait on the library with a timeout**, and nothing else may wait
  on it: the first PhotoKit call can take minutes. Background QoS, and the saver keeps
  using the index it has meanwhile.
- **The saver launches the app through a URL**, `NSWorkspace.open(URL("mosaic://…"))`,
  for the configure sheet's button and for "no index": the reason travels in the URL, and
  the app is launched by LaunchServices with its own grant. Never `Process`, which makes
  the app a child of `legacyScreenSaver`, and never arguments, which are dropped.
- **Consent still needs the user.** An app launched by the saver while the screen saver
  covers the screen must not ask for Photos: nobody would see the prompt. Without a grant
  it records why it was called and asks the next time the user opens it.
