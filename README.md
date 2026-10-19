# RootBeer

A native macOS app for managing Homebrew packages. Browse installed formulae and casks with their icons, upgrade them, and uninstall them along with dependencies nothing else needs.

Swift and SwiftUI, built with Swift Package Manager. No Xcode project, no third-party dependencies, no web views.

## Requirements

- macOS 14 or newer
- Command Line Tools (`xcode-select --install`). Xcode isn't needed.
- Homebrew at `/opt/homebrew` (Apple silicon) or `/usr/local` (Intel)

## Build and run

Build the app bundle:

```sh
./Scripts/build-app.sh
open build/RootBeer.app
```

The script runs `swift build -c release` and assembles `build/RootBeer.app`. It writes `Info.plist` (bundle id `com.local.rootbeer`) and ad-hoc signs the bundle with `codesign --sign -`. Drag the app to `/Applications` if you want to keep it.

Because the signature is ad-hoc, macOS may refuse to open a copy that was downloaded from somewhere else. A copy built on your own Mac opens normally.

For development:

```sh
swift build
.build/debug/RootBeer       # logs every brew command to stderr
swift test
```

## What it does

- **Browse:** a sidebar with All, Formulae, Casks and Outdated, each with a count, and a searchable grid of cards. Casks use their app's icon from `/Applications` or `~/Applications`; everything else uses an SF Symbol. Cards show *dependency* and *outdated* badges.
- **Details:** description, homepage, tap, dependencies, and what depends on the package (`brew uses --installed`).
- **Update Homebrew:** runs `brew update`.
- **Upgrade:** both one package and Upgrade All open a confirmation first. It shows old and new versions, when the list was loaded, and a reminder to run Update Homebrew first if the data may be stale.
- **Uninstall:** casks run `brew uninstall --cask NAME`, never `--zap`. Formulae open a plan, described below.
- **Cleanup:** shows the `brew cleanup --dry-run` output and asks before running `brew cleanup`.

Output from every command streams into the log panel. The result shows the exit status, and a non-zero exit is always shown as **FAILED**. If brew needs an administrator password, RootBeer stops and shows the exact command to paste into Terminal.

### Uninstalling a formula

RootBeer works out the removal set from the installed dependency graph:

1. Start with the package, plus any dependents you tick.
2. Add a dependency if it wasn't installed on request and everything installed that depends on it is already in the set.
3. Repeat until nothing changes.

The confirmation sheet lists the dependencies to remove, each with a checkbox (ticked by default). It also lists packages that depend on the one you're removing, as unticked rows. If any remain, the sheet shows a blocking warning. The **Force** checkbox only clears that warning. It never adds packages or flags to the brew command, so if brew refuses, RootBeer shows its error and stops.

The commands run in this order:

1. `brew uninstall --formula NAME` for each ticked dependent, then the package. Each one comes before anything it depends on.
2. `brew autoremove --dry-run` as a cross-check.
3. `brew uninstall --formula NAME` for each planned dependency that brew also lists, one at a time. Dependencies brew doesn't list are skipped and named in the log.

Plain `brew autoremove` is never run, because it would remove unrelated orphans. RootBeer also sets `HOMEBREW_NO_AUTOREMOVE=1`, so `brew uninstall` doesn't run one implicitly.

## Safety

- **One file runs brew:** `Sources/RootBeerCore/Brew.swift`. Its header lists every command RootBeer can run. Commands that change the system are cases of `BrewAction`, and the only way to run anything is through private `BrewRunner.run`.
- **One command at a time:** commands run strictly one after another through the `BrewRunner` actor, because concurrent brew calls conflict on locks. Action buttons are disabled while anything is running.
- **Explicit environment:** every brew process gets a fixed environment with a full `PATH`, since apps launched from Finder don't inherit your shell's. That environment also sets:
  - `HOMEBREW_NO_AUTO_UPDATE=1`: brew never updates itself behind your back. Use **Update Homebrew**.
  - `HOMEBREW_NO_INSTALL_CLEANUP=1`: upgrades keep old versions until you run **Cleanup**.
  - `HOMEBREW_NO_AUTOREMOVE=1`: since Homebrew 4.3, `brew uninstall` and `brew cleanup` otherwise run a system-wide `brew autoremove` afterwards, which removes unrelated orphans.
- **Result checked against reality:** after every operation, RootBeer reloads the package list and compares it with the list from before. Anything brew removed without being asked appears in an orange warning, and newly installed packages are listed.
- **No terminal input:** stdin is `/dev/null`, so a password prompt fails immediately instead of hanging.

Never used: `--zap`, plain `brew autoremove`, `--ignore-dependencies`, `--force`, `--greedy`.

## Project layout

```
Package.swift
Scripts/build-app.sh            release build → build/RootBeer.app
Sources/RootBeerCore/           no UI code; unit-tested
  Brew.swift                    all brew invocations
  Models.swift                  JSON decoding for brew info / brew outdated
  RemovalPlanner.swift          dependency graph and removal plan
Sources/RootBeer/               SwiftUI app
  RootBeerApp.swift, AppModel.swift, IconCache.swift, Views/
Tests/RootBeerTests/            Swift Testing; fixtures are trimmed real brew JSON
```

## Notes on building with only the Command Line Tools

- **Tests use Swift Testing.** XCTest isn't included with the Command Line Tools. Swift Testing is, but SwiftPM doesn't pass its macro plugin to every compile step. `Package.swift` adds `-plugin-path` for the test target when the plugin folder exists.
- **No `@State`.** In the macOS 27 SDK, SwiftUI's `@State` is a macro whose plugin only ships with Xcode. RootBeer stores `State(initialValue:)` explicitly instead, which works with every SDK.
- **Harmless warning.** `ld: warning: search path '…/Developer/Library/Frameworks' not found` is a Command Line Tools quirk.
