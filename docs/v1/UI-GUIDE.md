# UI Guide

Visual layout documentation for all Cacheout views and user interaction flows.

## Application Scenes

Cacheout has three scenes managed by `CacheoutApp`:

| Scene | Type | Access | Size |
|-------|------|--------|------|
| Main Window | `WindowGroup(id: "main")` | App launch / menubar button | 620×680 (min 560×500) |
| Menubar Popover | `MenuBarExtra(.window)` | Click menubar icon | 300px wide, auto height |
| Settings | `Settings` | ⌘, keyboard shortcut | 460×320 |

---

## Main Window (ContentView)

### Layout

```
┌─────────────────────────────────────────────┐
│  Cacheout                    [Scanning...]  │
│  Reclaim your disk space                     │
├─────────────────────────────────────────────┤
│  ┌─────────────────────────────────────┐    │
│  │ Macintosh HD          120 GB free   │    │
│  │ ████████████████░░░░░░░░            │    │
│  │ 380 GB of 500 GB used         76%   │    │
│  └─────────────────────────────────────┘    │
├─────────────────────────────────────────────┤
│                                              │
│  ◉ 🔨 Xcode DerivedData          5.2 GB  ✅ │
│     Build artifacts and indexes...           │
│                                              │
│  ○ 📱 Xcode Device Support       3.1 GB  🟡 │
│     Debug symbols for connected...           │
│                                              │
│  ◉ 📦 npm Cache                   1.8 GB  ✅ │
│     Cached npm packages...                   │
│                                              │
│  ○ 🧊 Docker Disk Image         24.3 GB  🔴 │
│     Docker's virtual disk...                 │
│                                              │
│  ... more categories ...                     │
│                                              │
│  ──────────────────────────────────────────  │
│                                              │
│  ▼ 📁 Project node_modules (12 found) 4.2GB │
│    [Select Stale] [Select All] [Deselect]    │
│                                              │
│    ◉ 📦 my-project          ~/Documents/...  │
│       3mo old                      890 MB    │
│                                              │
│    ○ 📦 another-app         ~/Developer/...  │
│                                     320 MB   │
│                                              │
├─────────────────────────────────────────────┤
│  Selection ▾  Selected: 7.0 GB    [Scan] [Clean Selected] │
└─────────────────────────────────────────────┘
```

### Components

| Component | View | Description |
|-----------|------|-------------|
| Header | `headerSection` | Title, subtitle, scan progress indicator |
| Disk Bar | `DiskUsageBar` | Visual disk usage with percentage |
| Category List | `CategoryRow` (×N) | Selectable cache categories |
| Node Modules | `NodeModulesSection` | Collapsible project list |
| Bottom Bar | `bottomBar` | Selection menu, scan button, clean button |

### Interactions

| Action | Result |
|--------|--------|
| Click category checkbox | Toggle selection |
| Click "Scan" | Run full scan |
| Click "Clean Selected" | Show confirmation sheet |
| Selection menu → "Select All Safe" | Select all safe, non-empty categories |
| Selection menu → "Deselect All" | Clear all selections |

### Sheets

| Sheet | Trigger | Content |
|-------|---------|---------|
| CleanConfirmationSheet | "Clean Selected" button | Item list, size total, trash toggle, caution warning |
| CleanupReportSheet | After cleanup completes | Freed space, per-category breakdown, errors |

---

## Menubar Popover (MenuBarView)

### Layout

```
┌──────────────────────────────┐
│  ┌────┐                      │
│  │ 76%│ Macintosh HD         │
│  │    │ 120 GB available     │
│  └────┘                      │
├──────────────────────────────┤
│   7.2 GB        │     15     │
│  Recoverable    │ Categories │
├──────────────────────────────┤
│  🔨 Xcode DerivedData 5.2 GB│
│  📦 npm Cache         1.8 GB│
│  🍺 Homebrew Cache    0.9 GB│
│  ⚡ VS Code Cache     0.3 GB│
│  🧪 Electron Cache    0.2 GB│
├──────────────────────────────┤
│  Scanned 5 min ago           │
│  🧊 Docker Prune      [Run] │
├──────────────────────────────┤
│  [Scan]  [Quick Clean]  [⊞] │
└──────────────────────────────┘
```

### Gauge Colors

| Usage | Color | Meaning |
|-------|-------|---------|
| < 85% | Blue | Normal |
| 85-95% | Orange | Warning |
| > 95% | Red | Critical (also shows warning badge on menubar icon) |

### Interactions

| Action | Result |
|--------|--------|
| Open popover | Auto-scan if data stale |
| Click "Scan" | Run full scan |
| Click "Quick Clean" | Smart clean (all safe categories) |
| Click "Run" (Docker) | Execute `docker system prune -f` |
| Click window icon (⊞) | Open main window |

---

## Settings Window (SettingsView)

### General Tab

```
┌─ Menubar Behavior ──────────────────┐
│  Scan interval          [30 min ▾]  │
│  Low-disk warning       [10 GB  ▾]  │
│  ☐ Launch at login                   │
├─ Current Disk Status ───────────────┤
│  Total disk              500 GB     │
│  Free space              120 GB     │
│  Used                    76%        │
└─────────────────────────────────────┘
```

### Cleaning Tab

```
┌─ Deletion Behavior ────────────────────┐
│  ☑ Move to Trash (recoverable)         │
│  Files are moved to Trash — you can    │
│  undo via Finder.                      │
├─ Docker ───────────────────────────────┤
│  Docker System Prune          [Prune]  │
│  Remove stopped containers...          │
│  Total reclaimed space: 1.2 GB         │
└────────────────────────────────────────┘
```

### Advanced Tab

```
┌─ Data ─────────────────────────────────┐
│  Categories scanned           25       │
│  Cleanup log        Reveal in Finder   │
│  Config directory       ~/.cacheout/   │
├─ About Cacheout ───────────────────────┤
│  Version                     1.0.0     │
│  Build                       1         │
│  Updates         [Check for Updates…]  │
└────────────────────────────────────────┘
```

---

## Menubar Icon

The menubar displays:
- Custom template icon (from `MenuBarIconTemplate.png`)
- Free GB text (e.g., "42GB")
- Warning badge overlay when disk usage > 95%

Fallback: SF Symbol `externaldrive.fill` if template image is missing.

---

## Color Coding

### Risk Level Colors

| Risk | Badge Color | Icon Color | Usage |
|------|-------------|------------|-------|
| Safe | Green capsule | Green | Category row icon, risk badge |
| Review | Orange capsule | Orange | Category row icon, risk badge |
| Caution | Red capsule | Red | Category row icon, risk badge, warning banner |

### Selection Colors

| Element | Selected | Unselected |
|---------|----------|------------|
| Category checkbox | Blue | Gray |
| Node modules checkbox | Purple | Gray |

### Disk Bar Colors

| Usage Level | Bar Color |
|-------------|-----------|
| < 85% | Blue |
| 85-95% | Orange |
| > 95% | Red |

---

## User Flows

### First Launch

1. App opens main window
2. Auto-scan triggers via `.task`
3. Disk usage bar appears
4. Categories populate sorted by size
5. Node modules scan continues in background
6. User selects items or uses "Select All Safe"
7. User clicks "Clean Selected"
8. Confirmation sheet appears
9. User confirms → cleanup runs
10. Report sheet shows results
11. Auto-rescan updates sizes

### Menubar Quick Clean

1. User clicks menubar icon
2. Popover opens, auto-scan if stale
3. User sees top 5 categories and stats
4. User clicks "Quick Clean"
5. All safe categories cleaned automatically
6. Disk info refreshes

### Settings Change

1. User presses ⌘,
2. Settings window opens
3. Changes to scan interval, threshold, or trash mode
4. Changes persist immediately via UserDefaults didSet
5. Next auto-scan tick uses new interval
