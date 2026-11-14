<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="CcinnRedis icon">
</p>

<h1 align="center">CcinnRedis</h1>

<p align="center">
  <b>A fast, native macOS client for Redis and Valkey — from Redis 2.8 to 8.x, standalone to cluster.</b><br>
  Browse millions of keys, edit every data type, and keep working through Sentinel, Redis Cluster and proxies such as twemproxy and Envoy.
</p>

<p align="center">
  <a href="https://github.com/whiteCcinn/ccinnredis/actions/workflows/ci.yml"><img src="https://github.com/whiteCcinn/ccinnredis/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/whiteCcinn/ccinnredis/releases/latest"><img src="https://img.shields.io/github/v/release/whiteCcinn/ccinnredis?sort=semver" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Redis-2.8%20%E2%86%92%208.x-d13848" alt="Redis 2.8 to 8.x">
  <img src="https://img.shields.io/badge/Valkey-8-6b4fbb" alt="Valkey 8">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-lightgrey" alt="MIT license"></a>
</p>

<p align="center">
  English · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <img src="docs/screenshots/key-browser-200k-light.png" alt="Key browser on a 200,000-key Redis 7.2" width="900">
</p>

## Why CcinnRedis?

Most Redis GUIs assume a modern, directly reachable, standalone server. They send `HELLO`, `CLIENT SETNAME`, `INFO` or `SCAN` unconditionally, so they break on Redis 2.8/3.x, on proxies that reject (or silently drop the connection on) those commands, and on clusters whose nodes announce private addresses.

CcinnRedis ships its **own pure-Swift Redis stack** — a bounded RESP2/RESP3 parser, connection pools, cluster/Sentinel/proxy routing and capability detection — so the same polished UI works on **Redis 2.8 → 8.x and Valkey**, in **every deployment mode**. It is a native SwiftUI/AppKit app: no Electron, no bundled runtimes, no telemetry.

## Features

- **Every server generation** — `HELLO 3` (RESP3) when available with automatic fallback to RESP2; `AUTH password` or ACL `AUTH user password`; capabilities (SCAN, SCAN TYPE, UNLINK, MEMORY USAGE, streams, functions, CLUSTER SHARDS, hash-field TTL…) detected from `INFO`, `COMMAND` and probing — never from assumptions.
- **Every deployment** — standalone, read-only replicas, **Sentinel** (resolves the master, follows failovers), **Redis Cluster** (slot map, `MOVED`/`ASK`, per-master scans, multi-key commands split by slot, topology view) and **proxies** — twemproxy/nutcracker, Codis, Predixy, Envoy and cloud proxy endpoints are detected and degrade gracefully with explanations instead of errors.
- **Connectivity** — `redis://`, `rediss://` (TLS with custom CA, client certificates), `unix://` sockets, `redis-sentinel://` and `redis-cluster://` URIs, **SSH tunnels** through your system OpenSSH (one forward per discovered node), and address maps for NAT/Docker clusters.
- **Key browser for millions of keys** — incremental `SCAN` (never `KEYS`), pattern and type filters, tree grouping by a delimiter with per-folder counts, a virtualised table, and lazy type/TTL loading for visible rows.
- **Editors for every type** — strings (text, JSON, hex), hashes, lists, sets, sorted sets, streams with consumer groups, consumers and pending entries, and **RedisJSON** documents; TTL, rename and delete (`UNLINK` when available).
- **Console** — redis-cli compatible input and output (RESP3 maps, sets, doubles…), command and key completion with syntax hints, per-profile history with secrets redacted, `SUBSCRIBE`/`MONITOR` streaming, cluster routing by key.
- **Server tools** — live dashboard (Swift Charts), full `INFO`, slow log, client list with kill, configuration, cluster topology with slot coverage, Pub/Sub viewer and publisher.
- **Memory analysis** — finds big keys by sampling with `SCAN` + `MEMORY USAGE` (or estimates on old servers and proxies), rate-limited, off the main thread and cancellable; totals by type, prefix and TTL; CSV export.
- **MCP server for AI clients** *(optional)* — let Claude Code, Claude Desktop, Codex and other MCP clients read the connections you enable; see [MCP server / AI access](#mcp-server--ai-access).
- **Safe by default** — per-connection read-only mode, replicas are read-only automatically, destructive operations are confirmed and `FLUSHDB`/`FLUSHALL` require typing the database or connection name. Passwords live in the macOS Keychain.

## Compatibility

| Server | Protocol | Notes | Tested live |
|---|---|---|---|
| Redis 2.8 | RESP2 | no UNLINK, MEMORY USAGE or streams — DEL and size estimates are used | ✅ |
| Redis 3.2, 4.0 | RESP2 | UNLINK and MEMORY USAGE from 4.0 | ✅ |
| Redis 5.0 | RESP2 | streams; streams are deleted with `DEL` (a 5.0 server bug crashes on `UNLINK` of some streams) | ✅ (requirepass) |
| Redis 6.2 | RESP3 | ACL users, `SCAN … TYPE` | ✅ (ACL user) |
| Redis 7.2, 7.4 | RESP3 | functions, CLUSTER SHARDS, hash-field TTL (7.4) | ✅ (200k keys, TLS) |
| Redis 8.x | RESP3 | | ✅ (8.2) |
| Valkey 8 | RESP3 | version read from `valkey_version` | ✅ |
| redis-stack 7.4 | RESP3 | RedisJSON editing, module detection | ✅ |
| Redis Cluster | RESP3/2 | 3 masters + 3 replicas, MOVED/ASK, replica scans | ✅ |
| Sentinel | RESP3/2 | master/replica resolution, live `SENTINEL FAILOVER` followed | ✅ |
| twemproxy | RESP2 | drops connections on unsupported commands — detected, keys opened by name | ✅ |
| Envoy Redis proxy | RESP2 | forwards `INFO` but rejects `HELLO`/`COMMAND` — detected by inconsistency | ✅ (1.36) |

CcinnRedis runs on **macOS 14 Sonoma or later** (Apple silicon and Intel).

## Screenshots

| Hash editor | Stream consumer groups |
|---|---|
| ![Hash](docs/screenshots/hash-editor-dark.png) | ![Stream groups](docs/screenshots/stream-groups-dark.png) |
| **Console with RESP3 replies** | **Live dashboard** |
| ![Console](docs/screenshots/console-dark.png) | ![Dashboard](docs/screenshots/dashboard-dark.png) |
| **Cluster topology and slot coverage** | **Memory analysis** |
| ![Cluster](docs/screenshots/cluster-dark.png) | ![Memory analysis](docs/screenshots/memory-analysis-dark.png) |
| **Through twemproxy (degraded, explained)** | **Connection editor** |
| ![twemproxy](docs/screenshots/twemproxy-dark.png) | ![Connections](docs/screenshots/connections-light.png) |
| **Sorted set** | **RedisJSON on redis-stack** |
| ![Sorted set](docs/screenshots/zset-editor-light.png) | ![RedisJSON](docs/screenshots/redisjson-dark.png) |

## Installation

1. Download `CcinnRedis-<version>.dmg` (or the `.zip`) from the [latest release](https://github.com/whiteCcinn/ccinnredis/releases/latest).
2. Open the disk image and drag **CcinnRedis** into **Applications**.
3. The app is ad-hoc signed but not notarized. The first time, right-click the app and choose **Open**, or run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/CcinnRedis.app
   ```

Each release lists SHA-256 checksums in `SHA256SUMS.txt`.

## Quick start

1. Click **New Connection**, choose **Standalone / Replica / Proxy**, **Sentinel** or **Cluster**, or press **Import URI** and paste `redis://user:password@host:6379/0`.
2. Press **Test** — it reports the server, deployment, protocol and key count — then **Save & Connect**.
3. Filter keys with a glob such as `user:*`, pick a type, and open a key. **⌘T** opens a console.

Useful shortcuts: **⌘T** new console · **⇧⌘R** reload keys · **⌥⌘I** connection details and capabilities · **⇧⌘D** disconnect · **⇧⌘[ / ]** switch tabs · in the console **↑/↓** history, **Tab**/**⌃Space** completion, **⇧↩** newline.

## Deployment modes

- **Standalone / replica** — connecting to a replica switches to read-only automatically. Connecting to a cluster node with a standalone profile switches to cluster routing; connecting to a Sentinel port explains that Sentinel mode is needed.
- **Sentinel** — list the sentinels and the master name; choose the master or a replica. Commands follow failovers (the master is re-resolved on connection failure or `READONLY`).
- **Cluster** — give one or more seed nodes. Keys are scanned on every master (or every replica, to spare the masters), commands are routed by hash slot, and `DEL`/`UNLINK`/`EXISTS`/`TOUCH`/`MGET`/`MSET` spanning several slots are split. If nodes announce addresses you cannot reach (Docker, NAT), add an **address map** such as `172.18.0.5 => 127.0.0.1`.
- **Proxies** — detected from behaviour (dropped connections, characteristic errors, a backend version that should know `HELLO`/`COMMAND`) or declared in the profile. Risky probes run on throw-away connections; every unavailable feature is listed with its reason in **Connection Details**, and keys can be opened by name when the proxy refuses `SCAN`.

## MCP server / AI access

CcinnRedis includes a [Model Context Protocol](https://modelcontextprotocol.io) server, so AI clients such as **Claude Code**, **Claude Desktop**, **Codex** or Cursor can inspect the Redis connections you saved in CcinnRedis — standalone, Sentinel, Cluster and proxies, including SSH tunnels. The server is the app's own executable started with the `mcp` subcommand; the app does not need to be open.

1. **Enable access per connection.** Edit a connection → **AI Access** → *Read-only* or *Read & write*, or use **Settings → AI Access**. Every connection starts *Disabled*.
2. **Register the server with your AI client.** **Settings → AI Access** shows these snippets with the exact path of your copy of the app:

   **Claude Code** (add `--scope user` to use it in every project):

   ```bash
   claude mcp add ccinnredis -- "/Applications/CcinnRedis.app/Contents/MacOS/CcinnRedis" mcp
   ```

   **Codex** (`~/.codex/config.toml`):

   ```toml
   [mcp_servers.ccinnredis]
   command = "/Applications/CcinnRedis.app/Contents/MacOS/CcinnRedis"
   args = ["mcp"]
   ```

   **Claude Desktop** (`claude_desktop_config.json`) and other JSON-configured clients:

   ```json
   {
     "mcpServers": {
       "ccinnredis": {
         "command": "/Applications/CcinnRedis.app/Contents/MacOS/CcinnRedis",
         "args": ["mcp"]
       }
     }
   }
   ```

Command-line options: `CcinnRedis mcp [--profile <name|id>] [--read-only]`. `--profile` chooses the connection for calls that do not name one; `--read-only` caps every connection at read-only access.

| Tool | What it does |
|---|---|
| `list_connections` | Connections enabled for AI access: name, id, endpoint summary, mode and access level. Never credentials. |
| `server_info` | Server family and version, deployment, protocol, unavailable features with reasons, modules and INFO sections. |
| `scan_keys` | Keys matching a pattern/type with type and TTL, via `SCAN` on every master; returns a cursor to continue. |
| `get_key` | A key's value, type-aware and bounded: strings (first 64 KB), hash/set pages, list and sorted-set ranges, stream entries, RedisJSON. |
| `key_info` | Type, TTL, encoding, element count, memory usage and idle time. |
| `slowlog` | Recent slow commands, merged across masters. |
| `cluster_info` | Cluster state and every node with role, master and slot ranges. |
| `run_command` | One allow-listed read-only command in redis-cli syntax, routed by key in a cluster. |
| `set_string` \* | `SET` a string, optionally with a TTL. |
| `delete_keys` \* | Deletes up to 100 named keys (`UNLINK` when available). |
| `expire_key` \* | Sets or removes a TTL. |

\* Only offered when a connection has *Read & write* access and the server was not started with `--read-only`.

**Safety model.**
- AI access is off for every connection until you enable it, and `--read-only` caps all connections.
- CcinnRedis classifies every `run_command` with its own command table (and the server's `COMMAND` flags) and refuses writes, `KEYS`, `FLUSH*`, `CONFIG SET`, `DEBUG`, `SHUTDOWN`, `MONITOR`, `SUBSCRIBE`, scripts and functions, `CLIENT KILL`/`PAUSE`, `ACL` user reads, blocking reads, transactions, `SELECT`, `AUTH` and unknown commands — before anything is sent. Secret values in `CONFIG GET` replies (`requirepass`, `masterauth`…) are redacted. Read-only connections also block writes inside the client.
- Limits: 200 items by default and at most 1,000 per call, about 256 KB per result (`truncated: true` when cut), and 30 seconds per call by default, at most 120. Cancelling a request in the client closes the connection that was running it.
- Passwords and SSH secrets stay in the Keychain; they are never passed on the command line or returned to the client.
- Every tool call is appended to `~/Library/Application Support/CcinnRedis/mcp-audit.jsonl` (time, connection, tool, redacted command or key, duration, item count, error). Values written with `set_string` and secrets are never logged.

## Building from source

Requirements: macOS 14+, Xcode 16 or later (Swift 6).

```bash
git clone https://github.com/whiteCcinn/ccinnredis.git
cd ccinnredis
swift build                          # debug build
swift test --skip IntegrationTests   # unit tests
scripts/build-app.sh --open          # build dist/CcinnRedis.app and launch it
scripts/package-release.sh 1.0.0     # universal .app, .zip, .dmg and checksums in dist/
```

### Integration tests against real servers

Docker is required. `scripts/redis-up.sh` starts memory-capped containers named `ccinnredis-it-*` on `127.0.0.1:17000-17999`, in groups — start a few at a time:

```bash
swift build                                   # the MCP test launches the built binary
scripts/redis-up.sh legacy modern             # Redis 2.8/3.2/4.0, 7.4/8.2/Valkey 8
CCINNREDIS_IT=1 CCINNREDIS_IT_GROUPS=legacy,modern swift test --filter IntegrationTests
scripts/redis-down.sh
scripts/redis-up.sh auth large tls stack      # 5.0 (requirepass) + 6.2 (ACL), 7.2 with 200,000 keys, TLS, redis-stack
CCINNREDIS_IT=1 CCINNREDIS_IT_GROUPS=auth,large,tls,stack swift test --filter IntegrationTests
scripts/redis-down.sh
scripts/redis-up.sh cluster sentinel proxy
CCINNREDIS_IT=1 CCINNREDIS_IT_GROUPS=cluster,sentinel,proxy swift test --filter IntegrationTests
scripts/redis-down.sh
```

`CCINNREDIS_IT_GROUPS` selects the groups you started (unset means all of them). Tests for a selected group whose server is down fail; they are never skipped silently.

The MCP integration test starts `CcinnRedis mcp` as a subprocess. It uses two **test-only** environment variables that are not meant for normal use: `CCINNREDIS_PROFILE_DIR=<path>` reads profiles from another folder (the audit log goes there too), and `CCINNREDIS_TEST_INSECURE_SECRETS_FILE=<json>` reads passwords from a JSON file instead of the Keychain.

## Architecture

```
CcinnRedis (SwiftUI/AppKit app, and the headless `mcp` subcommand)
 └─ CcinnRedisKit   profiles & Keychain, URI import, key tree, console (tokenizer, formatter, completion, history),
     │              value formats, memory analysis, MCP server
     └─ RedisKit    transport (Network.framework, TLS, Unix sockets, SSH tunnels), connection actor, pools,
         │          HELLO/AUTH handshake, capabilities, proxy detection, cluster/Sentinel routing, typed APIs
         └─ RESPWire   RESP2/RESP3 values, resumable bounded parser, encoder
```

- **One place decides what a connection can do:** `Capabilities` combines the version table, the server's command list, probes and runtime errors; the UI only reads capabilities.
- **Safe parsing:** the RESP parser keeps partially received aggregates on an explicit stack (linear time on huge replies) and enforces limits on string length, element count, nesting depth and line length; it is fuzz-tested.
- **Concurrency:** connections are actors used exclusively with explicit pipelining; cancellation or a timeout closes the socket and the pool replaces it. Tree building, sorting and analysis run off the main actor.

## The ccinn series

Native macOS database and storage tools that share the same design, speed and care:

| App | What it is |
|---|---|
| [**CcinnMongo**](https://github.com/whiteCcinn/ccinnmongo) | Native MongoDB client for every server from 2.6 to 8.x, with the legacy `OP_QUERY` and the modern `OP_MSG` protocols. |
| [**CcinnStarRocks**](https://github.com/whiteCcinn/ccinnstarrocks) | Native StarRocks client: partitions, tablets and skew, async and sync materialized views, running tasks, and SQL with completion and charts. |
| **CcinnRedis** *(this project)* | Native Redis client for Redis 2.8 → 8.x and Valkey; standalone, Sentinel, Cluster and proxies. |
| [**CcinnBucket**](https://github.com/whiteCcinn/ccinnbucket) | Object storage browser for Amazon S3, S3-compatible services and Alibaba Cloud OSS. |

## Contributors

- [whiteCcinn](https://github.com/whiteCcinn)

<a href="https://github.com/whiteCcinn/ccinnredis/graphs/contributors"><img src="https://contrib.rocks/image?repo=whiteCcinn/ccinnredis" alt="Contributors" /></a>

## Star history

[![Star History Chart](https://api.star-history.com/svg?repos=whiteCcinn/ccinnredis&type=Date)](https://star-history.com/#whiteCcinn/ccinnredis&Date)

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md), and report security issues privately as described in [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE) © 2026 whiteCcinn. Redis is a registered trademark of Redis Ltd. and Valkey is a trademark of the Linux Foundation; this project is not affiliated with or endorsed by either.
