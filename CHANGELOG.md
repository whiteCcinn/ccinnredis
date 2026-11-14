# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
- Safety: confirmations for destructive operations, typed confirmation for `FLUSHDB`/`FLUSHALL`.
- **MCP server for AI clients**: `CcinnRedis mcp [--profile <name|id>] [--read-only]` with per-connection opt-in, an app-enforced read-only command policy, bounded results, time limits, cancellation and an audit log; Settings → AI Access with Claude Code, Codex and Claude Desktop snippets.

### Notes

- Redis 5.0.x crashes (server assertion in `lazyfree.c`) when `UNLINK` frees a stream whose consumer groups were all destroyed; CcinnRedis deletes streams with `DEL` on Redis 5.

[Unreleased]: https://github.com/whiteCcinn/ccinnredis/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/whiteCcinn/ccinnredis/releases/tag/v1.0.0
