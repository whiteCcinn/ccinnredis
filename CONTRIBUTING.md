# Contributing to CcinnRedis

Thanks for taking the time to contribute! This document explains how to set up a development environment and what we expect from changes.

## Development setup

- macOS 14 or later, Xcode 16 or later (Swift 6).
- Docker, if you want to run the integration tests against real Redis servers.

```bash
git clone https://github.com/whiteCcinn/ccinnredis.git
cd ccinnredis
swift build
swift test --skip IntegrationTests
scripts/build-app.sh --open
```

### Integration tests

Containers are named `ccinnredis-it-*`, bound to `127.0.0.1:17000-17999` and capped at 128 MB each. Start a few groups at a time:

```bash
scripts/redis-up.sh legacy modern auth      # 2.8, 3.2, 4.0, 7.4, 8.2, Valkey 8, 5.0 (requirepass), 6.2 (ACL)
CCINNREDIS_IT=1 swift test --filter "Integration: standalone"
scripts/redis-down.sh
scripts/redis-up.sh large tls stack cluster sentinel proxy
CCINNREDIS_IT=1 swift test --filter IntegrationTests
scripts/redis-down.sh
```

The MCP integration test launches the built `CcinnRedis mcp`, so run `swift build` first. It uses the test-only variables `CCINNREDIS_PROFILE_DIR` and `CCINNREDIS_TEST_INSECURE_SECRETS_FILE`.

### Running the app against a server directly

```bash
.build/debug/CcinnRedis --connect 127.0.0.1:17072 --pattern 'demo:*' --key demo:hash:user:1
.build/debug/CcinnRedis --cluster 127.0.0.1:17101 --open cluster
.build/debug/CcinnRedis --sentinel 127.0.0.1:17311 --master mymaster --open console --console "ROLE; INFO replication"
```

Add `--appearance dark --snapshot /tmp/shot.png --snapshot-delay 8 --quit-after-snapshot` to render the window into a PNG (used for the screenshots; it needs no screen-recording permission and does not steal focus).

### Trying the MCP server

```bash
swift build
.build/debug/CcinnRedis mcp --help
claude mcp add ccinnredis-dev -- "$PWD/.build/debug/CcinnRedis" mcp
```

A debug build has a different code signature from the app that saved your Keychain items, so macOS asks once before it can read them.

## Project layout

| Module | Responsibility |
|---|---|
| `RESPWire` | RESP2/RESP3 values, resumable bounded parser and encoder (no I/O) |
| `RedisKit` | Transport, SSH tunnels, connections and pools, handshake, capabilities, proxy detection, cluster/Sentinel routing, typed APIs |
| `CcinnRedisKit` | UI-independent app logic: profiles, key tree, console, completion, value formats, memory analysis, MCP server |
| `CcinnRedis` | SwiftUI/AppKit application |

Dependencies only point downwards; lower modules must not import higher ones.

## Guidelines

- **Test first.** Add or update tests with every behaviour change. Protocol and routing logic is covered with the in-process fake server in `Tests/RedisKitTests/Support`, server-version behaviour with the integration suite.
- **Never crash on input.** No force unwraps/casts, unchecked indexing or trapping integer conversions on data from a server, a file or the user. Throw a descriptive error instead.
- **Capabilities, not version checks.** Feature differences between versions, Valkey and proxies belong in `Capabilities`; the UI reads capabilities only.
- **Proxies.** Never send a command that a proxy might refuse on a pooled connection before the capability is known; risky probes run on throw-away connections.
- **Concurrency.** Code must compile in Swift 6 strict-concurrency mode. Keep shared mutable state inside actors or behind small, well-scoped locks; do not block the main actor with I/O or heavy work.
- **Secrets** must never appear in logs, errors, history, the audit log or files.
- Keep pull requests focused, and update `CHANGELOG.md` under *Unreleased*.

## Commit messages

We use [Conventional Commits](https://www.conventionalcommits.org/): `feat(scope): …`, `fix(scope): …`, `docs: …`, `test: …`, `refactor: …`, `chore: …`.

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Make sure `swift build` and `swift test --skip IntegrationTests` pass.
3. Describe what changed and how you tested it (including Redis versions and deployment modes, if relevant).

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE). Please follow our [Code of Conduct](CODE_OF_CONDUCT.md).
