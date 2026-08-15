# Menu bar status items on macOS 26

Field notes from debugging "the menu bar icon never appears" on the
MirageControl Mac host. The conclusion is unintuitive enough, and cost enough
time, that it is worth writing down: **the bug was never in our code.**

Environment where this was reproduced and confirmed:

- macOS 26.6 (build `25G5043d`), 14" MacBook Pro (notched, 1512×982 pt)
- Xcode 26.6 (`17F113`)

## Symptom

The app launches, stays alive, and logs a perfectly healthy status item:

```
Status item created — visible=true length=-1.000000 hasImage=true
LoomContext started
```

No icon appears in the menu bar. Nothing is logged as an error. Clicking where
the icon should be does nothing, because there is nothing there.

This is easy to misread as the app crashing or quitting at launch — Xcode says
"Finished running" when you stop it — but the process is alive the whole time.

## Root cause

**Launching the app's executable directly, instead of through LaunchServices,
permanently poisons that bundle identifier's menu bar registration.**

Xcode's Run button launches macOS apps this way. So the first `⌘R` is what
breaks it, and it stays broken forever after.

Once a bundle ID is poisoned, *every* subsequent launch of that ID is affected,
including a correct `open -a` launch. The state is keyed to the bundle
identifier, not the app path, the signature, or the binary.

### Demonstration

With a brand-new, never-used bundle identifier:

| Step | How it was launched | `statusItem.button.window.frame` | Icon |
| --- | --- | --- | --- |
| 1 | `open -a Foo.app` | `(1018, 949, 53, 33)` | visible |
| 2 | `./Foo.app/Contents/MacOS/Foo` | `(0, -17, 53, 22)` | absent |
| 3 | `open -a Foo.app` | `(1459, 960, 53, 22)` | absent |
| 4 | `open -a Foo.app` | `(0, -17, 53, 22)` | absent |

Step 2 is the poisoning event. Steps 3 and 4 are correct launches that now fail.

### The tell

A healthy status item window on this display is **33 pt tall** — it matches the
menu bar, which the Window Server reports as `(0, 0, 1512, 33)`.

A poisoned one is **22 pt tall**, AppKit's legacy default, and is parked either
against the right edge of the screen (underneath Control Center's own items) or
fully off-screen at a negative origin. Multiple status items from the same
poisoned process stack on top of each other at the same coordinates instead of
being assigned distinct slots.

So the height is the fastest signal: **22 means the menu bar server never
adopted the item; 33 means it did.**

## What this is *not*

Each of these was tested and eliminated. Listing them because every one of them
is a plausible-sounding theory that costs an afternoon:

- `MenuBarExtra` vs. a hand-rolled `NSStatusItem`
- SwiftUI `App` + `@NSApplicationDelegateAdaptor` vs. a pure AppKit `@main`
- `NSStatusItem.autosaveName`, and `behavior` / `isVisible` settings
- `LSUIElement`, and `NSApp.setActivationPolicy(.accessory)`
- Deployment target (`minos 14.0` vs `26.0`) and linked SDK
- Hardened runtime, entitlements, sandboxing, signing identity, provisioning
- Linking LoomKit, SwiftUI, or any framework
- The app's own source files
- `Info.plist` contents
- The Xcode 16+ debug dylib split (`ENABLE_DEBUG_DYLIB`)
- Duplicate LaunchServices registrations of the same bundle ID
- A notched display, or the menu bar being full

The decisive experiment: a probe target compiling **all** of MirageControl's
sources, linking LoomKit, using its exact `Info.plist`, entitlements and
hardened runtime, placed its icon correctly — while a 20-line stock AppKit app
with none of our code failed the moment its bundle ID was poisoned.

## What does *not* clear it

- Deleting DerivedData, rebuilding, reinstalling
- Removing the app and re-signing it (ad-hoc or Developer ID)
- `killall ControlCenter` / `killall SystemUIServer`
- `lsregister -r -domain local -domain system -domain user`
- Deleting `NSStatusItem Visible Item-*` from `com.apple.controlcenter`
- Removing every copy of the app from disk and from LaunchServices

The store backing this state was not located. It is in no user preference
domain under `~/Library`, and it survives all of the above. Whether a reboot
clears it is untested.

## The fix

1. **Use a bundle identifier that has never been poisoned.** A poisoned one
   appears to be unrecoverable on that machine.
2. **Never launch the built executable directly.** Use `open -a`, or Finder.
3. **In Xcode**, set the scheme's Info → Launch to *"Wait for the executable to
   be launched"*. The app is then started by LaunchServices and Xcode attaches
   to it, so debugging works without poisoning the identifier.

Point 3 is the one that matters day to day — without it, the next `⌘R` burns
the new bundle ID too.

## Diagnosing it

Two techniques did all the work.

**1. Log the status item's real geometry.** `isVisible` lies; the window frame
does not.

```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
    print("win=\(String(describing: statusItem.button?.window?.frame))")
}
```

Height 22 → broken. Height 33 (matching the menu bar) → healthy.

**2. Enumerate what is actually on screen.** This needs no Screen Recording
permission, and shows every status item from every app, so you can see whether
yours was given a slot at all:

```swift
import CoreGraphics

let list = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
) as? [[String: Any]] ?? []

for w in list {
    guard let b = w[kCGWindowBounds as String] as? [String: Any],
          let y = b["Y"] as? Double, y < 40,
          let h = b["Height"] as? Double, h < 45 else { continue }
    print(w[kCGWindowOwnerName as String] ?? "?", b)
}
```

If your item is missing from that list while your process reports it as visible,
the menu bar server never accepted it.

**3. Always A/B against a control.** A ~20-line AppKit app that does nothing but
create a status item is the single most useful tool here. It tells you instantly
whether the machine or the app is at fault, and it is what turned this from
guesswork into a bisect.

## Trap for the unwary

Because Xcode's Run poisons the identifier, **bisecting through git history to
find "the commit that broke it" gives a false answer.** Old commits build under
the same already-poisoned bundle ID and fail identically, which looks like the
bug has always existed. The variable that matters is the bundle ID's state and
the launch method, and git history does not vary either.
