# Configuration

## UserDefaults Keys

All user preferences are stored in `UserDefaults.standard` and persist across app launches.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `cacheout.scanIntervalMinutes` | `Double` | `30.0` | Auto-scan interval in minutes |
| `cacheout.lowDiskThresholdGB` | `Double` | `10.0` | Low-disk notification threshold in GB |
| `cacheout.launchAtLogin` | `Bool` | `false` | Whether to launch at login |
| `cacheout.lastLowDiskNotification` | `Double` | `0` | Unix timestamp of last low-disk notification |

### Scan Interval Options

| Value | Display |
|-------|---------|
| `15.0` | 15 min |
| `30.0` | 30 min (default) |
| `60.0` | 1 hour |
| `120.0` | 2 hours |
| `240.0` | 4 hours |

### Low-Disk Threshold Options

| Value | Display |
|-------|---------|
| `5.0` | 5 GB |
| `10.0` | 10 GB (default) |
| `15.0` | 15 GB |
| `20.0` | 20 GB |
| `25.0` | 25 GB |
| `50.0` | 50 GB |

## File System Locations

### Application Data

| Path | Purpose |
|------|---------|
| `~/.cacheout/` | Application data directory |
| `~/.cacheout/cleanup.log` | Cleanup history log (ISO 8601 timestamps) |

### Cleanup Log Format

Each line follows this format:
```
[2026-01-15T10:30:00Z] Cleaned Xcode DerivedData: 5.2 GB
[2026-01-15T10:30:01Z] Cleaned npm Cache: 1.8 GB
[2026-01-15T10:30:01Z] Cleaned node_modules/my-project: 890 MB
```

### Spotlight Markers

When the `spotlight` CLI command is run:

| Path | Purpose |
|------|---------|
| `<cache-dir>/.cacheout-managed` | Marker file for `mdfind -name` queries |

Marker file format:
```
slug: xcode_derived_data
name: Xcode DerivedData
risk: Safe
size: 5.2 GB
tagged: 2026-01-15T10:30:00Z
```

### Extended Attributes

The `spotlight` command also sets:
```
com.apple.metadata:kMDItemFinderComment = "cacheout-managed: <slug>"
```

## Info.plist Configuration

### Required Keys

| Key | Value | Notes |
|-----|-------|-------|
| `CFBundleIdentifier` | `com.cacheout.app` | Required for notifications to work |
| `LSMinimumSystemVersion` | `14.0` | macOS Sonoma minimum |

### Sparkle Configuration

| Key | Value | Notes |
|-----|-------|-------|
| `SUFeedURL` | (not set) | Set to appcast URL to enable auto-updates |

When `SUFeedURL` is not set, Sparkle initializes but the "Check for Updates" button
is disabled.

## Environment Variables

Shell commands (probes and clean commands) run with a restricted environment:

```bash
PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin
HOME=<user home directory>
```

This ensures consistent behavior regardless of the user's shell configuration.

## Timeouts

| Operation | Timeout | On Timeout |
|-----------|---------|------------|
| Path probe commands | 2 seconds | Process terminated, fallback paths used |
| Custom clean commands | 30 seconds | Process terminated, error reported |
| Low-disk notification throttle | 1 hour | Notification suppressed |

## Notification Configuration

Notifications require:
1. A valid `CFBundleIdentifier` in the running bundle (not available in `.build/release/` mode)
2. User permission (requested on first launch via `UNUserNotificationCenter`)

Notification content:
- **Title:** "Disk Space Low"
- **Body:** "Only X.X GB free. Open Cacheout to reclaim X.X GB of caches."
- **Sound:** Default system sound
- **Identifier:** `lowDisk` (replaces previous low-disk notifications)
