# Security policy

AeroOps holds SSH keys, host passwords and host keys, and lets AI agents run commands on your servers. Security reports are welcome.

## Reporting a vulnerability

Report it privately through [GitHub's private vulnerability reporting](https://github.com/gusquadri/AeroOps/security/advisories/new). Do not open a public issue.

Include the AeroOps version (AeroOps › About AeroOps, or the release tag), your macOS or iOS version, steps to reproduce, and what an attacker gains. You will get an answer within a week.

## Supported versions

Only the latest release gets security fixes. Installed copies update themselves through Sparkle.

## In scope

- Private keys, passwords or tokens leaving the Keychain or Secure Enclave: to disk, logs, MCP responses or the network.
- `aeroops-mcp` or another local process reaching `bridge.sock` or `askpass.sock` without a valid code signature.
- Exec tools running on a host whose policy tier does not allow them.
- Host key checks that can be bypassed, or a changed host key that does not block the host.
- Remote command injection through values AeroOps interpolates into commands.
- Release integrity: the signed DMG, the Sparkle zip and the appcast signature.

## Out of scope

- An agent running a command on a Read + Exec host without asking you first. AeroOps tells the agent to ask but does not enforce it; keep hosts at Read when that matters.
- Attacks that need root or an unlocked session on your Mac.
