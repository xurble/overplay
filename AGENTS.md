# AGENTS.md

## Purpose

This document defines the rules and expectations for AI agents working
in this SwiftUI project.

Agents may read, modify, and create code to help implement features, fix
bugs, and improve structure, but must follow the constraints below.

Agents should **modify the smallest possible amount of code** required
to implement a change.

------------------------------------------------------------------------

# Critical Rules

## Never Commit to Git

Agents **must never run any git commands that modify repository state**.

Forbidden commands include:

-   git commit
-   git push
-   git merge
-   git rebase
-   git reset
-   git checkout
-   git cherry-pick
-   git stash

Agents may inspect git state using read‑only commands such as:

-   git status
-   git diff
-   git log

All commits and branch management are performed **only by the human
developer**.

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

## Deployment Target

This project targets **iOS 26 and later only**.

Agents should:

-   Assume **iOS 26 APIs are available**
-   Prefer **modern frameworks and APIs**
-   Avoid compatibility code for older iOS versions

Do **not** add availability checks unless explicitly requested.

------------------------------------------------------------------------

## Liquid Glass UI

The interface is designed specifically for **iOS 26 Liquid Glass design
language**.

Agents should prefer:

-   system materials
-   glass‑style surfaces
-   layered translucency and depth
-   modern SwiftUI animations and interactions

Avoid:

-   skeuomorphic styling
-   legacy flat iOS design patterns
-   UIKit styling approaches

UI should feel **native to modern iOS 26**.

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

Avoid introducing UIKit wrappers unless explicitly required.

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

Avoid UIKit gesture recognizers unless necessary.

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
-   **iOS 26+**
-   **Liquid Glass UI**
