# AeroOps

Native macOS 26+ SwiftUI app: SSH-based server monitoring cards, Docker and Kubernetes status and logs, libghostty SSH terminal tabs, and a local MCP server (`aeroops-mcp`) for AI agents. An iOS 26+ companion (`AeroOpsMobile`) has the monitoring cards, host details, the host editor, keys, and a libghostty terminal and SFTP file browser per host.

## Layout
- `Packages/AeroKit`: everything below the UI, for both platforms. Terminals: `TerminalKit` (Mac, over SSHKit) and `EmbeddedTerminal` (iOS, over `EmbeddedSSH`) share `TerminalStyle`.
- `Shared/`: SwiftUI views and models compiled into both apps. They take values and closures, never `AppModel` or `MobileModel`; Mac-only conveniences go in `App/…+App.swift`, platform differences behind `#if os(macOS)`.
- `App/`: the Mac app (`AppModel`). `Mobile/`: the iOS app (`MobileModel`).
- Put a view in `Shared/` when both apps need it, rather than writing it twice.

## Rules
- Secrets live only in the Keychain or Secure Enclave. Never write private keys, passwords or tokens to disk, logs, fixtures or MCP responses.
- On macOS, all remote access goes through SSHKit: system `/usr/bin/ssh` + `~/.aeroops/ssh_config` + the in-app agent. No other SSH code paths or SSH libraries.
- iOS has no `ssh` binary: the iOS app's only SSH path is AeroKit's `EmbeddedSSH` (swift-nio-ssh). It uses the same `HostKeyStore` pinning and blocking, `KeyStore` keys, `HostPasswordVault` and signing policies, and runs the same remote scripts. Never use `EmbeddedSSH` in the Mac app or `aeroops-mcp`.
- Remote scripts are POSIX `sh`, run with `LC_ALL=C`, BusyBox-compatible, and live in `Scripts/remote/`.
- Every value interpolated into a remote command goes through `ShellQuote.quote`.
- MCP exec-tier work always goes through `PolicyEngine` (per-host tiers). Never bypass it, not even in tests; use hosts at the tier you need. AeroOps does not ask before `run_command`; the MCP instructions tell the agent to ask the user.
- Swift 6 strict concurrency: UI on `@MainActor`, per-host state in actors.
- Views use `AeroTheme` tokens only; no hard-coded colours, radii or fonts.
- Never pass `CharacterSet.contains` as a function value (`allSatisfy(set.contains)`); write a closure `{ set.contains($0) }`. Swift 6.4 -O miscompiles it, and only release builds break.
- Edit `project.yml`, never the `.xcodeproj` (generated and git-ignored, except its `Package.resolved`, which pins every Swift package; commit it when packages change).

## Commands
- Generate project: `xcodegen generate`
- Build: `xcodebuild -scheme AeroOps -destination 'platform=macOS' build`
- Build iOS: `xcodebuild -scheme AeroOpsMobile -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build` (iOS 27.0 runtime; check the foldable layout on `name=iPhone Duo`, iOS 27.1)
- Run iOS on sample data: `xcrun simctl launch booted app.aeroops.AeroOpsMobile -AeroOpsDemo` (add `-AeroOpsScreen host|terminal|files|add|edit|keys|newKey|key` to open a screen)
- Tests: `swift test --package-path Packages/AeroKit`
- Dev SSH server: `docker compose -f dev/compose.yml up -d` (dev@localhost:2222; the Simulator reaches it too)
- Authorize a public key on the dev SSH server: `dev/add-key.sh <path-to.pub>`
- Release: push a `vX.Y.Z` tag; `.github/workflows/release.yml` builds, notarizes and publishes it

## Workflow
- Plan first, then implement.
- Before calling a task done: build, run tests, fix failures. A change to `Shared/` or `Packages/AeroKit` builds both apps.
