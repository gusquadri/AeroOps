# AeroOps

## Rules
- Secrets live only in the Keychain or Secure Enclave. Never write private keys, passwords or tokens to disk, logs, fixtures or MCP responses.
- All remote access goes through SSHKit: system `/usr/bin/ssh` + `~/.aeroops/ssh_config` + the in-app agent. No other SSH code paths or SSH libraries.
- Remote scripts are POSIX `sh`, run with `LC_ALL=C`, BusyBox-compatible, and live in `Scripts/remote/`.
- Every value interpolated into a remote command goes through `ShellQuote.quote`.
- MCP exec-tier work always goes through `PolicyEngine` and `ApprovalCenter`. Never bypass them, not even in tests; use a test policy.
- Swift 6 strict concurrency: UI on `@MainActor`, per-host state in actors.
- Views use `AeroTheme` tokens only; no hard-coded colours, radii or fonts.
- Edit `project.yml`, never the `.xcodeproj` (generated and git-ignored).

## Commands
- Generate project: `xcodegen generate`
- Build: `xcodebuild -scheme AeroOps -destination 'platform=macOS' build`
- Tests: `swift test --package-path Packages/AeroKit`
- Dev SSH server: `docker compose -f dev/compose.yml up -d` (dev@localhost:2222)
- Authorize a public key on the dev SSH server: `dev/add-key.sh <path-to.pub>`

## Workflow
- Before calling a task done: build, run tests, fix failures.
