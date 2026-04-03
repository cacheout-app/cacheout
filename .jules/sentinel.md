## 2024-11-20 - Defense-in-Depth against Command Injection

**Vulnerability:** Use of `/bin/bash -c` string pipelines with dynamic substitution to probe developer cache paths and run category cleanup commands (like `docker system prune` and `xcrun simctl`).
**Learning:** Even static shell commands in system utilities expose unnecessary risk surface because path logic and environments can be hijacked by downstream agents or environment configurations.
**Prevention:** Eliminate all `/bin/bash` wrappers. Refactor shell pipelines (like `head -1 | sed`) directly into Swift `String` manipulations and structure all process commands using `[[String]]` step arrays routed via `URL(fileURLWithPath: "/usr/bin/env")`. Use identical `Pipe()` handles to replace `2>&1` securely.
