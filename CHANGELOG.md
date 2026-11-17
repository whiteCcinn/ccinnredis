# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.2.1] - 2026-11-17

### Fixed

- SSH tunnels no longer become a shared connection master. With `ControlMaster auto` in `~/.ssh/config`, the tunnel of one CcinnRedis window could become the master that other windows and your own terminal sessions were multiplexed over, so closing that window cut them all. Tunnels now pass `-o ControlMaster=no`; an existing master of yours is still used.

### Docs

- The File menu item that opens an empty window is **New CcinnRedis Window** (⌘N); the README called it "New Window".

## [1.2.0] - 2026-11-17

### Added

- **Multiple windows made easy.** File ▸ **New Window with This Connection** (⇧⌘N) and the toolbar's **New Window** button open the current connection in another window, with the secrets already in use (password, Sentinel password, SSH secret, TLS key password) and the database you are browsing, so unsaved connections and secrets that are not in the Keychain work too; nothing is saved. Saved connections have **Open in New Window**, and the connection screen has a **New Window** button. Every window keeps its own connection; closing one disconnects only that window.

### Fixed

- Closing a window while it is still connecting cancels the connection attempt. The connection used to finish in the background and stay open, SSH tunnel included.

## [1.1.0] - 2026-11-16

### Added

- **Check for Updates…** in the app menu. When a newer release exists, CcinnRedis shows its version and release notes. **Download & Open** downloads the disk image, verifies its size and SHA-256 against the release's `SHA256SUMS.txt`, saves it to Downloads without overwriting anything, and opens it. **Release Page**, **Skip This Version** and **Later** are also available.
- A quiet automatic check at most once a day (retried after an hour when offline), on by default, switchable in **Settings → General → Updates**.
- Project links: the Help menu now has **CcinnRedis on GitHub**, **Release Notes** and **Report an Issue…**; the About window shows the GitHub link; Settings → General shows the version and project links.

## [1.0.0] - 2026-11-14

First public release.

### Added

- Pure-Swift Redis stack: RESP2/RESP3 values, a resumable parser with hard limits (bulk length, element count, nesting depth, line length; fuzz-tested), pipelining and Pub/Sub framing.
- Works with **Redis 2.8 → 8.x and Valkey**: `HELLO 3` with automatic RESP2 fallback (including proxies that drop the connection on `HELLO`), `AUTH password` and ACL `AUTH user password`, capabilities detected from `INFO`, `COMMAND`, probes and runtime errors.
- Deployment modes: standalone, read-only replicas, **Sentinel** (master/replica resolution, failover following), **Redis Cluster** (`CLUSTER SHARDS`/`SLOTS`/`NODES`, `MOVED`/`ASK`/`TRYAGAIN`, per-master or per-replica scans, slot-split `DEL`/`UNLINK`/`EXISTS`/`TOUCH`/`MGET`/`MSET`) and **proxies** (twemproxy, Codis, Predixy, Envoy, cloud endpoints) with graceful degradation and explanations.
- Connectivity: TCP, TLS (custom CA, client certificates, SNI), Unix sockets, SSH tunnels per discovered node, address maps for NAT/Docker, URI import (`redis://`, `rediss://`, `unix://`, `redis-sentinel://`, `redis-cluster://`).
- Connection manager with mode-specific forms, Keychain secrets, test connection, read-only mode and favourites.
- Key browser for millions of keys: incremental `SCAN`, pattern and type filters, delimiter tree with counts, virtualised table, lazy type/TTL, database picker, open-by-name when `SCAN` is unavailable.
- Editors for strings (text/JSON/hex), hashes, lists, sets, sorted sets, streams (entries, consumer groups, consumers, pending) and RedisJSON; TTL, rename, delete (`UNLINK` when available).
- Console with redis-cli compatible tokenizer and reply formatting, completion (commands, subcommands, options, keys) with syntax hints, redacted per-profile history, `SUBSCRIBE`/`MONITOR` streaming and cluster routing.
- Live dashboard with Swift Charts, `INFO`, slow log, clients (kill), configuration, cluster topology with slot coverage, Pub/Sub viewer and publisher.
- Memory analysis by rate-limited sampling (`MEMORY USAGE`, `DEBUG OBJECT` or length estimates) with totals by type, prefix and TTL, and CSV export.
- Safety: confirmations for destructive operations, typed confirmation for `FLUSHDB`/`FLUSHALL` (the connection name when the selected database is not known); read-only mode is an allowlist; list edits verify the element they change (`WATCH`/`MULTI`), so a concurrently modified list is never edited at the wrong index.
- **MCP server for AI clients**: `CcinnRedis mcp [--profile <name|id>] [--read-only]` with per-connection opt-in, an app-enforced read-only command policy, bounded reads (no whole-collection replies, ranges and counts capped), redaction of secrets, time limits, cancellation and a multi-process-safe audit log; Settings → AI Access with Claude Code, Codex and Claude Desktop snippets.

### Notes

- Redis 5.0.x crashes (server assertion in `lazyfree.c`) when `UNLINK` frees a stream whose consumer groups were all destroyed; CcinnRedis deletes streams with `DEL` on Redis 5.

[Unreleased]: https://github.com/whiteCcinn/ccinnredis/compare/v1.2.1...HEAD
[1.2.1]: https://github.com/whiteCcinn/ccinnredis/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/whiteCcinn/ccinnredis/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/whiteCcinn/ccinnredis/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/whiteCcinn/ccinnredis/releases/tag/v1.0.0
