<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="CcinnRedis 图标">
</p>

<h1 align="center">CcinnRedis</h1>

<p align="center">
  <b>快速、原生的 macOS Redis / Valkey 客户端 —— 从 Redis 2.8 到 8.x，从单机到集群。</b><br>
  浏览百万级键、编辑所有数据类型，并且在 Sentinel、Redis Cluster 以及 twemproxy、Envoy 等代理后面照样可用。
</p>

<p align="center">
  <a href="https://github.com/whiteCcinn/ccinnredis/actions/workflows/ci.yml"><img src="https://github.com/whiteCcinn/ccinnredis/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/whiteCcinn/ccinnredis/releases/latest"><img src="https://img.shields.io/github/v/release/whiteCcinn/ccinnredis?sort=semver" alt="最新版本"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Redis-2.8%20%E2%86%92%208.x-d13848" alt="Redis 2.8 到 8.x">
  <img src="https://img.shields.io/badge/Valkey-8-6b4fbb" alt="Valkey 8">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-lightgrey" alt="MIT 许可证"></a>
</p>

<p align="center">
  <a href="README.md">English</a> · 简体中文
</p>

<p align="center">
  <img src="docs/screenshots/key-browser-200k-light.png" alt="在 20 万键的 Redis 7.2 上浏览键" width="900">
</p>

## 为什么是 CcinnRedis？

大多数 Redis 图形客户端默认面对的是一台新版本、可直连的单机 Redis：它们会无条件地发送 `HELLO`、`CLIENT SETNAME`、`INFO` 或 `SCAN`。于是在 Redis 2.8/3.x 上、在拒绝这些命令（甚至直接断开连接）的代理后面、以及在节点公布内网地址的集群上，它们都会出错。

CcinnRedis 自带一套 **纯 Swift 实现的 Redis 协议栈** —— 有边界保护的 RESP2/RESP3 解析器、连接池、集群 / Sentinel / 代理路由和能力探测 —— 因此同一套精致的界面可以用于 **Redis 2.8 → 8.x 以及 Valkey**，覆盖 **所有部署形态**。它是原生 SwiftUI/AppKit 应用：没有 Electron，没有内置运行时，没有遥测。

## 功能

- **兼容所有版本** —— 支持时使用 `HELLO 3`（RESP3），否则自动回退到 RESP2；自动选择 `AUTH 密码` 或 ACL 的 `AUTH 用户 密码`；SCAN、SCAN TYPE、UNLINK、MEMORY USAGE、Stream、Functions、CLUSTER SHARDS、哈希字段 TTL 等能力全部通过 `INFO`、`COMMAND` 和探测得出，而不是想当然。
- **兼容所有部署形态** —— 单机、只读副本、**Sentinel**（解析主节点并跟随故障转移）、**Redis Cluster**（槽位映射、`MOVED`/`ASK`、逐个主节点扫描、跨槽多键命令自动拆分、拓扑视图）以及 **代理** —— twemproxy/nutcracker、Codis、Predixy、Envoy 和云厂商代理端点都会被识别，并且优雅降级、给出原因说明而不是报错。
- **连接方式** —— `redis://`、`rediss://`（TLS，支持自定义 CA 和客户端证书）、`unix://` 套接字、`redis-sentinel://` 与 `redis-cluster://` URI；通过系统 OpenSSH 建立 **SSH 隧道**（为每个发现的节点建立转发）；为 NAT / Docker 集群提供地址映射。
- **面向百万级键的键浏览器** —— 增量 `SCAN`（从不使用 `KEYS`）、模式与类型过滤、按分隔符分组的树形结构及每个目录的键数、虚拟化表格、只为可见行按需加载类型和 TTL。
- **所有类型的编辑器** —— 字符串（文本、JSON、十六进制）、哈希、列表、集合、有序集合、Stream（含消费者组、消费者和待处理消息）以及 **RedisJSON** 文档；支持设置 TTL、重命名和删除（可用时使用 `UNLINK`）。
- **控制台** —— 与 redis-cli 一致的输入与输出（含 RESP3 的 map、set、double 等），命令与键名补全及语法提示，按连接保存且已脱敏的历史记录，`SUBSCRIBE`/`MONITOR` 流式输出，集群中按键路由。
- **服务器工具** —— 实时仪表盘（Swift Charts）、完整 `INFO`、慢日志、客户端列表（可断开）、配置、带槽位覆盖图的集群拓扑、Pub/Sub 查看与发布。
- **内存分析** —— 通过 `SCAN` + `MEMORY USAGE`（旧版本和代理上使用估算）抽样查找大键，限速、在主线程之外运行、可随时取消；按类型、前缀和 TTL 汇总；可导出 CSV。
- **面向 AI 客户端的 MCP 服务器**（可选）—— 让 Claude Code、Claude Desktop、Codex 等 MCP 客户端读取你授权的连接，见 [MCP 服务器 / AI 访问](#mcp-服务器--ai-访问)。
- **默认安全** —— 每个连接可设为只读，副本连接自动只读，危险操作都需要确认，`FLUSHDB`/`FLUSHALL` 必须输入数据库编号或连接名称。密码保存在 macOS 钥匙串中。

## 兼容性

| 服务器 | 协议 | 说明 | 实测 |
|---|---|---|---|
| Redis 2.8 | RESP2 | 无 UNLINK、MEMORY USAGE 和 Stream —— 使用 DEL 与大小估算 | ✅ |
| Redis 3.2、4.0 | RESP2 | 4.0 起支持 UNLINK 和 MEMORY USAGE | ✅ |
| Redis 5.0 | RESP2 | 支持 Stream；Stream 用 `DEL` 删除（5.0 的一个服务器缺陷会在 `UNLINK` 某些 Stream 时崩溃） | ✅（requirepass） |
| Redis 6.2 | RESP3 | ACL 用户、`SCAN … TYPE` | ✅（ACL 用户） |
| Redis 7.2、7.4 | RESP3 | Functions、CLUSTER SHARDS、哈希字段 TTL（7.4） | ✅（20 万键、TLS） |
| Redis 8.x | RESP3 | | ✅（8.2） |
| Valkey 8 | RESP3 | 版本读取自 `valkey_version` | ✅ |
| redis-stack 7.4 | RESP3 | RedisJSON 编辑、模块探测 | ✅ |
| Redis Cluster | RESP3/2 | 3 主 3 从、MOVED/ASK、从副本扫描 | ✅ |
| Sentinel | RESP3/2 | 主 / 副本解析，实测跟随 `SENTINEL FAILOVER` | ✅ |
| twemproxy | RESP2 | 遇到不支持的命令会断开连接 —— 可识别，按名称打开键 | ✅ |
| Envoy Redis 代理 | RESP2 | 转发 `INFO` 但拒绝 `HELLO`/`COMMAND` —— 通过不一致性识别 | ✅（1.36） |

CcinnRedis 运行于 **macOS 14 Sonoma 及更高版本**（Apple 芯片与 Intel）。

## 截图

| 哈希编辑器 | Stream 消费者组 |
|---|---|
| ![哈希](docs/screenshots/hash-editor-dark.png) | ![Stream 消费者组](docs/screenshots/stream-groups-dark.png) |
| **控制台与 RESP3 回复** | **实时仪表盘** |
| ![控制台](docs/screenshots/console-dark.png) | ![仪表盘](docs/screenshots/dashboard-dark.png) |
| **集群拓扑与槽位覆盖** | **内存分析** |
| ![集群](docs/screenshots/cluster-dark.png) | ![内存分析](docs/screenshots/memory-analysis-dark.png) |
| **通过 twemproxy（降级并给出说明）** | **连接编辑器** |
| ![twemproxy](docs/screenshots/twemproxy-dark.png) | ![连接](docs/screenshots/connections-light.png) |
| **有序集合** | **redis-stack 上的 RedisJSON** |
| ![有序集合](docs/screenshots/zset-editor-light.png) | ![RedisJSON](docs/screenshots/redisjson-dark.png) |

## 安装

1. 从 [最新发布](https://github.com/whiteCcinn/ccinnredis/releases/latest) 下载 `CcinnRedis-<版本>.dmg`（或 `.zip`）。
2. 打开磁盘映像，把 **CcinnRedis** 拖到 **应用程序**。
3. 应用采用临时签名（ad-hoc）且未经过公证。首次打开时请右键点击应用并选择 **打开**，或执行：

   ```bash
   xattr -dr com.apple.quarantine /Applications/CcinnRedis.app
   ```

每个发布都附带 `SHA256SUMS.txt` 校验和。

## 快速上手

1. 点击 **New Connection**，选择 **Standalone / Replica / Proxy**、**Sentinel** 或 **Cluster**；也可以点 **Import URI** 粘贴 `redis://user:password@host:6379/0`。
2. 点 **Test** —— 会显示服务器、部署形态、协议和键数量 —— 然后 **Save & Connect**。
3. 用 `user:*` 之类的通配模式过滤键、选择类型，然后打开一个键。**⌘T** 打开控制台。

常用快捷键：**⌘T** 新控制台 · **⇧⌘R** 重新加载键 · **⌥⌘I** 连接详情与能力 · **⇧⌘D** 断开 · **⇧⌘[ / ]** 切换标签页 · 控制台中 **↑/↓** 历史、**Tab**/**⌃Space** 补全、**⇧↩** 换行。

## 部署形态

- **单机 / 副本** —— 连接到副本时自动切换为只读。用单机配置连接到集群节点会自动切换为集群路由；连接到 Sentinel 端口时会提示需要使用 Sentinel 模式。
- **Sentinel** —— 填写哨兵地址和主节点名称，选择连接主节点或副本。命令会跟随故障转移（连接失败或收到 `READONLY` 时重新解析主节点）。
- **Cluster** —— 填写一个或多个种子节点。键会在每个主节点（或为减轻主节点压力而在每个副本）上扫描，命令按哈希槽路由，跨多个槽的 `DEL`/`UNLINK`/`EXISTS`/`TOUCH`/`MGET`/`MSET` 会被拆分。如果节点公布的地址无法访问（Docker、NAT），可以添加 **地址映射**，例如 `172.18.0.5 => 127.0.0.1`。
- **代理** —— 根据行为（断开连接、特征性错误、后端版本本应支持 `HELLO`/`COMMAND`）识别，或在配置中声明。有风险的探测都在一次性连接上执行；每个不可用的功能及其原因都列在 **Connection Details** 中；当代理拒绝 `SCAN` 时可以按名称打开键。

## MCP 服务器 / AI 访问

CcinnRedis 内置 [Model Context Protocol](https://modelcontextprotocol.io) 服务器，**Claude Code**、**Claude Desktop**、**Codex**、Cursor 等 AI 客户端可以通过你在 CcinnRedis 中保存的连接查看 Redis 数据 —— 单机、Sentinel、Cluster 与代理，包括 SSH 隧道。服务器就是应用自身的可执行文件加上 `mcp` 子命令，无需打开应用。

1. **按连接开启访问。** 编辑连接 → **AI Access** → *Read-only*（只读）或 *Read & write*（读写），或使用 **Settings → AI Access**。所有连接默认 *Disabled*（关闭）。
2. **在 AI 客户端中注册服务器。** **Settings → AI Access** 会显示以下配置片段，并填好你本机应用的实际路径：

   **Claude Code**（加 `--scope user` 可在所有项目中使用）：

   ```bash
   claude mcp add ccinnredis -- "/Applications/CcinnRedis.app/Contents/MacOS/CcinnRedis" mcp
   ```

   **Codex**（`~/.codex/config.toml`）：

   ```toml
   [mcp_servers.ccinnredis]
   command = "/Applications/CcinnRedis.app/Contents/MacOS/CcinnRedis"
   args = ["mcp"]
   ```

   **Claude Desktop**（`claude_desktop_config.json`）及其他使用 JSON 配置的客户端：

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

命令行参数：`CcinnRedis mcp [--profile <名称|id>] [--read-only]`。`--profile` 指定调用未注明连接时使用的连接；`--read-only` 把所有连接限制为只读。

| 工具 | 作用 |
|---|---|
| `list_connections` | 已开启 AI 访问的连接：名称、id、地址摘要、模式和访问级别。绝不返回凭据。 |
| `server_info` | 服务器类型与版本、部署形态、协议、不可用的功能及原因、模块和 INFO 各节。 |
| `scan_keys` | 通过在每个主节点上 `SCAN` 返回匹配模式 / 类型的键及其类型和 TTL，并给出继续扫描的游标。 |
| `get_key` | 按类型读取键值且有上限：字符串（前 64 KB）、哈希 / 集合分页、列表与有序集合区间、Stream 条目、RedisJSON。 |
| `key_info` | 类型、TTL、编码、元素数量、内存占用和空闲时间。 |
| `slowlog` | 最近的慢命令，跨主节点合并。 |
| `cluster_info` | 集群状态以及每个节点的角色、主节点和槽位区间。 |
| `run_command` | 一条允许列表中的只读命令（redis-cli 语法），集群中按键路由。 |
| `set_string` \* | `SET` 字符串，可选 TTL。 |
| `delete_keys` \* | 删除最多 100 个指定名称的键（可用时使用 `UNLINK`）。 |
| `expire_key` \* | 设置或移除 TTL。 |

\* 仅当连接的访问级别为 *Read & write* 且服务器未以 `--read-only` 启动时提供。

**安全模型。**
- 每个连接默认关闭 AI 访问，必须手动开启；`--read-only` 会限制所有连接。
- CcinnRedis 使用自己的命令表（以及服务器 `COMMAND` 返回的标志）对每条 `run_command` 进行分类，在发送之前就拒绝写命令、`KEYS`、`FLUSH*`、`CONFIG SET`、`DEBUG`、`SHUTDOWN`、`MONITOR`、`SUBSCRIBE`、脚本与 Functions、`CLIENT KILL`/`PAUSE`、读取 ACL 用户、阻塞读取、事务、`SELECT`、`AUTH` 以及未知命令。`CONFIG GET` 回复中的敏感值（`requirepass`、`masterauth` 等）会被隐去。只读连接在客户端内部也会拦截写命令。
- 限制：默认每次 200 条、最多 1,000 条，每个结果约 256 KB（被截断时带 `truncated: true`），每次调用默认 30 秒、最多 120 秒。在客户端取消请求会关闭正在执行该请求的连接。
- 密码和 SSH 密钥始终保存在钥匙串中，绝不会出现在命令行，也不会返回给客户端。
- 每次工具调用都会追加记录到 `~/Library/Application Support/CcinnRedis/mcp-audit.jsonl`（时间、连接、工具、脱敏后的命令或键名、耗时、条目数、错误）。`set_string` 写入的值和任何密钥都不会被记录。

## 从源码构建

环境要求：macOS 14+，Xcode 16 或更高版本（Swift 6）。

```bash
git clone https://github.com/whiteCcinn/ccinnredis.git
cd ccinnredis
swift build                          # 调试构建
swift test --skip IntegrationTests   # 单元测试
scripts/build-app.sh --open          # 构建 dist/CcinnRedis.app 并启动
scripts/package-release.sh 1.0.0     # 在 dist/ 中生成通用 .app、.zip、.dmg 与校验和
```

### 针对真实服务器的集成测试

需要 Docker。`scripts/redis-up.sh` 会按分组启动名为 `ccinnredis-it-*`、绑定在 `127.0.0.1:17000-17999` 且限制内存的容器 —— 请每次只启动少量分组：

```bash
scripts/redis-up.sh legacy modern auth   # Redis 2.8/3.2/4.0、7.4/8.2/Valkey 8、5.0（requirepass）+ 6.2（ACL）
scripts/redis-up.sh large tls stack      # 含 20 万键的 Redis 7.2、TLS、redis-stack
scripts/redis-up.sh cluster sentinel proxy
swift build                              # MCP 测试会启动构建出的可执行文件
CCINNREDIS_IT=1 swift test --filter IntegrationTests
scripts/redis-down.sh
```

未启动的服务器对应的测试会因连接失败而失败，因此请只运行与已启动分组对应的测试套件（例如 `--filter "Integration: cluster"`）。

MCP 集成测试会以子进程方式启动 `CcinnRedis mcp`。它使用两个 **仅供测试** 的环境变量，正常使用时不应设置：`CCINNREDIS_PROFILE_DIR=<路径>` 从其他目录读取连接配置（审计日志也写到那里），`CCINNREDIS_TEST_INSECURE_SECRETS_FILE=<json>` 从 JSON 文件而不是钥匙串读取密码。

## 架构

```
CcinnRedis（SwiftUI/AppKit 应用，以及无界面的 `mcp` 子命令）
 └─ CcinnRedisKit   连接配置与钥匙串、URI 导入、键树、控制台（分词、格式化、补全、历史）、
     │              值格式、内存分析、MCP 服务器
     └─ RedisKit    传输（Network.framework、TLS、Unix 套接字、SSH 隧道）、连接 actor、连接池、
         │          HELLO/AUTH 握手、能力探测、代理识别、集群 / Sentinel 路由、类型化 API
         └─ RESPWire   RESP2/RESP3 值、可续接且有边界的解析器、编码器
```

- **由一个地方决定连接能做什么：** `Capabilities` 综合版本表、服务器命令列表、探测和运行时错误；界面只读取能力，不判断版本号。
- **安全解析：** RESP 解析器把尚未收完的聚合类型保存在显式栈中（超大回复也是线性时间），并限制字符串长度、元素数量、嵌套深度和行长度；经过模糊测试。
- **并发：** 连接是独占使用的 actor，通过显式流水线提升吞吐；取消或超时会关闭套接字，由连接池补充新连接。构建键树、排序和分析都在主线程之外进行。

## ccinn 系列

风格一致、同样追求速度与细节的原生 macOS 数据库与存储工具：

| 应用 | 简介 |
|---|---|
| [**CcinnMongo**](https://github.com/whiteCcinn/ccinnmongo) | 原生 MongoDB 客户端，支持 2.6 到 8.x 的所有服务器，兼容旧的 `OP_QUERY` 与新的 `OP_MSG` 协议。 |
| [**CcinnStarRocks**](https://github.com/whiteCcinn/ccinnstarrocks) | 原生 StarRocks 客户端：分区、Tablet 与数据倾斜、异步 / 同步物化视图、运行中的任务，以及带补全和图表的 SQL。 |
| **CcinnRedis**（本项目） | 原生 Redis 客户端，支持 Redis 2.8 → 8.x 与 Valkey；单机、Sentinel、Cluster 与代理。 |
| [**CcinnBucket**](https://github.com/whiteCcinn/ccinnbucket) | 对象存储浏览器，支持 Amazon S3、S3 兼容服务与阿里云 OSS。 |

## 贡献者

- [whiteCcinn](https://github.com/whiteCcinn)

<a href="https://github.com/whiteCcinn/ccinnredis/graphs/contributors"><img src="https://contrib.rocks/image?repo=whiteCcinn/ccinnredis" alt="Contributors" /></a>

## Star 历史

[![Star History Chart](https://api.star-history.com/svg?repos=whiteCcinn/ccinnredis&type=Date)](https://star-history.com/#whiteCcinn/ccinnredis&Date)

## 参与贡献

欢迎贡献！请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)；安全问题请按 [SECURITY.md](SECURITY.md) 的说明私下报告。

## 许可证

[MIT](LICENSE) © 2026 whiteCcinn。Redis 是 Redis Ltd. 的注册商标，Valkey 是 Linux Foundation 的商标；本项目与二者均无关联，也未获其认可。
