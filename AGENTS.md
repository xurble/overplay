# AGENTS.md

## Purpose

This document defines the rules and expectations for AI agents working
in this SwiftUI project.

Agents may read, modify, and create code to help implement features, fix
bugs, and improve structure, but must follow the constraints below.

Agents should **modify the smallest possible amount of code** required
to implement a change.


------------------------------------------------------------------------

# Platform Requirements

## Swift Version

This project uses **Swift 6**.

Agents must:

-   Write **Swift 6 compatible code**
-   Prefer **modern Swift concurrency**
-   Avoid patterns that conflict with Swift 6 strict concurrency

Prefer:

-   async/await
-   Task
-   @MainActor
-   Sendable where appropriate

Avoid:

-   legacy completion handlers unless necessary
-   outdated Swift syntax

------------------------------------------------------------------------

## Deployment Targets

This project targets **iOS 26, iPadOS 26, and macOS 26 and later only**.

Agents should:

-   Assume **iOS 26, iPadOS 26, and macOS 26 APIs are available**
-   Prefer **modern frameworks and APIs**
-   Avoid compatibility code for older OS versions

Do **not** add availability checks unless explicitly requested.

------------------------------------------------------------------------

## Liquid Glass UI

The interface is designed specifically for the **Liquid Glass design
language** across iPhone, iPad, and Mac.

Agents should prefer:

-   system materials
-   glass‑style surfaces
-   layered translucency and depth
-   modern SwiftUI animations and interactions
-   platform-native navigation, windowing, menus, and controls

Avoid:

-   skeuomorphic styling
-   legacy flat Apple platform design patterns
-   UIKit or AppKit styling approaches unless required for a specific
    platform capability

UI should feel **native to modern iOS 26, iPadOS 26, and macOS 26**.

------------------------------------------------------------------------

# Development Guidelines

## SwiftUI First

Use **SwiftUI exclusively** unless there is a strong reason not to.

Prefer:

-   View composition
-   @State
-   @Binding
-   @Observable
-   @Environment

Avoid introducing UIKit or AppKit wrappers unless explicitly required.

Prefer adaptive SwiftUI structure across targets:

-   compact navigation for iPhone
-   split views and sidebars for iPad where appropriate
-   native Mac windows, toolbars, menus, keyboard shortcuts, and tables where
    appropriate

------------------------------------------------------------------------

## Shared Playback Surface Infrastructure

All playback surfaces should use **common playback, persistence, presentation,
and action infrastructure** so actions performed in one surface immediately
affect the others.

This applies to SwiftUI app views, CarPlay, Lock Screen controls, Control
Center, Siri, AirPods/headset controls, remote commands, Dynamic Island,
widgets, shortcuts, and any other place that can start, stop, skip, queue,
shuffle, repeat, or mutate current-track state.
    
Agents should:

-   Route shared actions through common controllers, use cases, services, and
    repositories rather than duplicating surface-specific logic.
-   Treat CarPlay templates, SwiftUI views, remote command handlers, widgets,
    and other surfaces as thin adapters over shared state and shared
    presentation models.
-   Ensure playback, queue, shuffle, repeat, and current-track health actions
    update the same observable state regardless of which surface initiated the
    action.
-   Ensure surface-initiated actions update the state and command metadata used
    by SwiftUI, CarPlay, Lock Screen, Control Center, Siri, AirPods, Dynamic
    Island, and remote controls.
-   Add tests at the shared-controller or use-case layer when possible, so both
    app UI and external playback surfaces are protected by the same regression
    coverage.

How:

-   Put durable behavior in shared types such as playback controllers, action
    services, repositories, presentation factories, and command services.
-   Route system playback events through the same command path used by the app,
    typically `MPRemoteCommandCenter` handlers calling the shared playback
    controller.
-   After persistence writes that affect current playback UI, update the shared
    observable playback state immediately rather than waiting for polling or a
    later MusicKit refresh.
-   After any surface-initiated playback change, reconcile local queue state and
    now-playing metadata through the shared playback controller so SwiftUI rows,
    now-playing views, Dynamic Island metadata, CarPlay controls, and system
    playback surfaces stay in sync.
-   When refreshing CarPlay templates, update the currently visible template
    where practical instead of resetting the template stack, so browsing state
    is not lost during playback or background refreshes.
-   Keep surface-specific code limited to platform APIs, view/template
    construction, navigation, presentation, and adapter glue.

------------------------------------------------------------------------

## Keep Views Small

Views should remain **composable and focused**.

Guideline:

-   Prefer multiple small views over large monolithic views
-   Extract reusable components early

------------------------------------------------------------------------

## Naming Conventions

Types\
PascalCase

Variables / functions\
camelCase

Views should typically end with `View`.

Examples:

NumberPadView\
SettingsView\
LoginButtonView

------------------------------------------------------------------------

## Avoid Over‑Engineering

Prefer:

-   clear code
-   simple structures
-   minimal abstraction

Do **not introduce complex architectures** unless explicitly requested.

Avoid adding:

-   heavy dependency injection frameworks
-   unnecessary protocols
-   complex state management systems

------------------------------------------------------------------------

## Safe Refactoring

Agents may:

-   improve readability
-   remove unused code
-   simplify logic

Agents must **not change existing behaviour** unless explicitly
instructed.

------------------------------------------------------------------------

## Pre-release Data Policy

This app is pre-release and has no user data compatibility promise yet.

Agents should:

-   Deprioritize persistent data migration work until beta or release
    hardening.
-   Prefer simple schema resets or development-only cleanup when model shape
    changes, if that matches existing project patterns.
-   Keep release-time data upgrade notes lightweight and explicit when a
    change may matter later.

Agents should not:

-   Add complex compatibility layers, historical preservation shims, or
    released-data upgrade paths unless explicitly requested.
-   Treat local development data as something that must be preserved.

Before a public beta or release, revisit this policy and design the required
data upgrade path deliberately.

------------------------------------------------------------------------

## Unit Tests for Code Changes

Code changes should be accompanied by unit tests that exercise the
changed behaviour.

Agents should:

-   Add or update Swift Testing unit tests for new logic, bug fixes, and
    behavioural changes
-   Use in-memory SwiftData containers or lightweight mocks where practical
-   Keep tests focused on the changed behaviour
-   Run the relevant test target when possible and report the result

If a change cannot reasonably be unit tested, agents should explain why
and describe what verification was performed instead.

------------------------------------------------------------------------

# SwiftUI Stability Rules

## Keep Previews Working

All views should include a working preview.

Agents should:

-   Ensure new views include a `#Preview`
-   Avoid preview crashes
-   Use lightweight mock data when needed

Example:

#Preview { NumberPadView() }

Previews should compile quickly and remain stable.

------------------------------------------------------------------------

## Layout Safety

Avoid patterns that commonly break SwiftUI layout.

Agents should **not**:

-   Nest excessive GeometryReaders
-   Create infinite layout loops
-   Overuse `.frame(maxWidth: .infinity, maxHeight: .infinity)`
-   Force layout using long Spacer chains

Prefer:

-   VStack / HStack / ZStack
-   Grid or LazyVGrid
-   containerRelativeFrame
-   alignment and padding

Layouts should be **predictable and adaptive**.

------------------------------------------------------------------------

## Animation Guidelines

Animations should use **modern SwiftUI APIs**.

Prefer:

withAnimation(.spring()) { }

or

.animation(.smooth, value: state)

Avoid:

-   deprecated animation APIs
-   large implicit animations on complex views
-   unnecessary DispatchQueue.main.async

Animations should feel **native and responsive**.

------------------------------------------------------------------------

## Gestures & Interaction

Use SwiftUI gesture systems.

Prefer:

-   DragGesture
-   TapGesture
-   GestureState

Avoid UIKit or AppKit gesture recognizers unless necessary.

------------------------------------------------------------------------

## Performance Awareness

Avoid patterns that degrade SwiftUI performance.

Avoid:

-   deeply nested views with heavy modifiers
-   repeated expensive work inside `body`
-   unnecessary view invalidations

Prefer:

-   computed properties
-   smaller reusable views
-   stable state ownership

------------------------------------------------------------------------

# Project Interaction Rules

Agents may:

-   create new Swift files
-   modify SwiftUI views
-   implement features
-   improve layouts and animations
-   refactor code safely

Agents must **not**:

-   commit code
-   change git history
-   introduce large dependencies without approval
-   restructure the project without confirmation

------------------------------------------------------------------------

# When Unsure

If a task would require:

-   large architectural changes
-   removing significant parts of the project
-   adding major dependencies

The agent should **ask for confirmation first**.

------------------------------------------------------------------------

# Summary

Allowed:

-   editing SwiftUI code
-   adding views and components
-   safe refactoring
-   using modern Swift 6 features

Forbidden:

-   **any git commit, push, or repository‑changing git command**

Platform assumptions:

-   **Swift 6**
-   **iOS 26+, iPadOS 26+, macOS 26+**
-   **Liquid Glass UI**
