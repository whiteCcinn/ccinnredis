# Security Policy

## Supported versions

Security fixes are released for the latest minor version of CcinnRedis.

| Version | Supported |
|---|---|
| 1.0.x | ✅ |

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Report vulnerabilities privately through GitHub's [private vulnerability reporting](https://github.com/whiteCcinn/ccinnredis/security/advisories/new). Include:

- a description of the issue and its impact,
- steps to reproduce (Redis/Valkey version, deployment mode, connection options, sample data if relevant),
- any suggested fix.

You can expect an acknowledgement within a few days. Once a fix is available, we will publish a release and an advisory crediting the reporter (unless you prefer to remain anonymous).

## Scope and design notes

- Passwords, sentinel passwords, TLS certificate passwords and SSH secrets are stored in the macOS Keychain; saved profiles on disk never contain them. Console history redacts secrets in `AUTH`, `HELLO … AUTH`, `ACL SETUSER`, `MIGRATE … AUTH` and `CONFIG SET *pass*`.
- Read-only profiles and replica connections block write commands inside the client before anything is sent. Any way to make a read-only connection write is a security vulnerability.
- The MCP server (`CcinnRedis mcp`) only uses connections the user enabled for AI access and enforces read-only access itself. Any way for an MCP client to write through a read-only connection, run a refused command (scripts, `CONFIG SET`, `FLUSH*`, `DEBUG`, `SHUTDOWN`…), exceed the documented limits, or obtain passwords or SSH secrets is a security vulnerability.
- `CCINNREDIS_TEST_INSECURE_SECRETS_FILE` and `CCINNREDIS_PROFILE_DIR` exist for automated tests only. Do not set them in normal use.
- SSH tunnels use the system `/usr/bin/ssh` with `StrictHostKeyChecking=accept-new`: changed host keys are rejected. Host and user values are validated so they cannot inject `ssh` options.
- Update checks contact only `api.github.com` and `github.com`, send no personal data (the User-Agent is `CcinnRedis/<version>`), and run at most once a day unless you check manually. A downloaded disk image is accepted only from this repository's download URL for the same release tag, at the size the release lists, and with the SHA-256 published in that release's `SHA256SUMS.txt`. The checksum guards against corruption and truncation, not against a compromised GitHub release; authenticity relies on HTTPS to github.com. The app never replaces itself; you drag the new version into Applications.
