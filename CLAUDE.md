# AeroOps

## Rules
- Secrets live only in the Keychain or Secure Enclave. Never write private keys, passwords or tokens to disk, logs, fixtures or MCP responses.
- All remote access goes through SSHKit: system `/usr/bin/ssh` + `~/.aeroops/ssh_config` + the in-app agent. No other SSH code paths or SSH libraries.
- Remote scripts are POSIX `sh`, run with `LC_ALL=C`, BusyBox-compatible, and live in `Scripts/remote/`.
- Every value interpolated into a remote command goes through `ShellQuote.quote`.
- MCP exec-tier work always goes through `PolicyEngine` (per-host tiers). Never bypass it, not even in tests; use hosts at the tier you need. AeroOps does not ask before `run_command`; the MCP instructions tell the agent to ask the user.
- Swift 6 strict concurrency: UI on `@MainActor`, per-host state in actors.
- Views use `AeroTheme` tokens only; no hard-coded colours, radii or fonts.
- Edit `project.yml`, never the `.xcodeproj` (generated and git-ignored).

## Commands
- Generate project: `xcodegen generate`
- Build: `xcodebuild -scheme AeroOps -destination 'platform=macOS' build`
- Tests: `swift test --package-path Packages/AeroKit`
- Dev SSH server: `docker compose -f dev/compose.yml up -d` (dev@localhost:2222)
- Authorize a public key on the dev SSH server: `dev/add-key.sh <path-to.pub>`
- Release: push a `vX.Y.Z` tag; `.github/workflows/release.yml` builds, notarizes and publishes it

## Workflow
- Before calling a task done: build, run tests, fix failures.
