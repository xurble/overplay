# Sidebar Navigation: Implementation Notes

How a sidebar choice changes the list in the regular-width shell
(`Overplay/App/Shell/SplitAppShell.swift`), and the traps found on the way.
It shipped in PR #108 (merged as `dd26bca`, 2026-10-31). The product rule is
in `OVERPLAY_DESIGN_SPEC.md`: a sidebar choice shows no pop or push, only a
fade of the list.

## What happens on a choice

The dashboard is always the list stack's root, and a sidebar screen is pushed
on it by value, so Back leads home. A choice runs through
`showSelectedDestination()`:

1. `SplitAppShell.sidebarSwitchPath(to:from:shown:)` decides what to do:
   - **Nothing** (`nil`): the choice is already on top. That means the
     dashboard with an empty path, or a screen whose path already holds it,
     such as one a dashboard link opened by value. No new screen would arrive
     to end a fade, so there is no fade.
   - **Another path**: the usual case, a different screen or the dashboard.
   - **An empty path**: the choice is already in the path but a screen opened
     inside it covers it. Screens opened by view aren't in the path, so
     `shownDestination` tracks which sidebar screen is actually on top.
     Emptying the path leaves the covering screen, and the choice is pushed
     again (step 3). The dashboard can't leave such a screen this way,
     because its path is already empty. Only One True Playlist creation is
     affected.
2. The list (the detail `NavigationStack`) fades out over 0.12 s
   (`isDetailFaded`). Then `detailPath` is set inside the same stack, in a
   `disablesAnimations` transaction, while the list can't be seen.
3. `destinationView` reports arrival with `.task(id: destination)`, which
   runs when a screen appears and also when the path swaps it in place.
   - When the chosen screen arrives, the list fades back in over 0.2 s
     (`revealDetail`).
   - When the dashboard arrives with an empty path while a switch is pending,
     the chosen screen is pushed on it. This covers both the deliberate
     emptying in step 1 and a stack that dropped the new path.
   - If nothing arrives within 1.5 s, the list is shown anyway.
4. `switchGeneration` lets the latest choice win. An earlier choice still
   fading or waiting gives way, and every choice bumps the generation, even
   one that changes nothing.

`isSwitchingDestination` stays set from the fade-out until the reveal. While
it is set, an empty path is not read as "Back to the dashboard": the
`detailPath.count == 0` handler leaves the sidebar's selection alone.

## Traps found

These came from recording the iPad simulator under a temporary UI test, with
timestamped `Logger` lines read through `log show --info`. Timing tweaks
alone did not find them.

- **A new stack per choice lingers.** Replacing the stack (`.id` bump) left
  the old one on screen for up to about a second. It had popped back to its
  own dashboard, which is the "navigating via the dashboard" the owner kept
  seeing.
- **A path given with a new stack is pushed later, animated.** It took 100 to
  800 ms, so a fixed wait sometimes ended before the push and showed it.
- **The split view's hidden sidebar drives the detail column.** While the
  panel stands in for the sidebar, the split view's own sidebar List is
  hidden. If it shares the selection, the split view pops the detail stack
  to its root the moment a choice is made. In panel mode it gets
  `.constant(nil)`.
- **Don't turn off UIKit animations globally.** With
  `UIView.setAnimationsEnabled(false)` around the swap, later choices didn't
  fade and the new screen never reported in.
- **An in-place swap fires no `onAppear`.** Setting a one-entry path to
  another one-entry path updates the pushed view in place. `.task(id:)`
  fires; `onAppear` does not.
- **Simulator recordings can't show a fade.** `simctl io recordVideo` writes
  only frames that change, at a variable rate. Use logs for the order of
  events, and a device for how a fade looks.

## Related shell behaviour

- **Compact home button.** Both shells' dashboards wrote `compactHome.isAway`
  as they appeared and disappeared. Folding the phone on the dashboard let
  the split shell's dashboard disappear after the compact one appeared, which
  showed the home button. The split shell now clears `compactHome` from its
  environment. The button exists only in the compact shell.
- **Keyboard.** The shell's size and fold are measured by a background view
  that ignores the keyboard, so the keyboard never changes the layout.
  Stacked, the keyboard covers the shell. Side by side, it shortens the list,
  which scrolls clear of it.

## Tests

- `OverplayTests/SidebarSwitchTests.swift`: the `sidebarSwitchPath` decisions.
- `OverplayUITests/SidebarNavigationUITests.swift`, on the iPad simulator:
  - a choice replaces the screen;
  - choosing the screen shown changes nothing;
  - Back leads to the dashboard;
  - choosing Settings again from inside Find Duplicates returns to Settings.
- Not covered automatically: how the fade looks, the home button after
  folding, and the keyboard during layout changes. Check these on a device.
