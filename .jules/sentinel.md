## 2026-04-24 - Avoid Shell Interpolation for Executables

**Vulnerability:** Shell interpolation risk in `toolExists` when running `/usr/bin/which \(tool)`.
**Learning:** Using `shell("...")` with string interpolation can lead to command injection if `tool` contains untrusted characters.
**Prevention:** Use direct `Foundation.Process` execution by setting `process.executableURL` and passing arguments as an array (`process.arguments = [tool]`). For suppressing output, use `FileHandle.nullDevice` assigned directly to `process.standardOutput` and `process.standardError` rather than shell redirection (`2>/dev/null`).
