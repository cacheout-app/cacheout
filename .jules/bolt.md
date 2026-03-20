# Performance Optimization Journal

## Optimization: Lazy Evaluation of Process Identifier Set Creation

**Date:** 2026-03-04
**File:** `Sources/Cacheout/Intervention/Tier2Interventions.swift:240`

### 💡 What
Added `.lazy` to the `NSWorkspace.shared.runningApplications` collection before the `filter` and `map` operations used to create `foregroundPIDs`.

### 🎯 Why
The original code:
```swift
Set(NSWorkspace.shared.runningApplications
    .filter { $0.isActive }
    .map { $0.processIdentifier })
```
creates two intermediate arrays:
1. An array containing only the active applications.
2. An array containing only the process identifiers of those active applications.

By using `.lazy`, these intermediate array allocations are avoided. The `filter` and `map` operations are performed just-in-time as the `Set` is initialized, reducing peak memory usage and CPU cycles spent on allocations and copies.

### 📊 Measured Improvement
Since the development environment is Linux and the code is macOS-specific, direct benchmarking is not possible. However, this is a standard Swift performance optimization that reduces O(N) intermediate allocations. Given that `runningApplications` can contain many entries, avoiding two array copies is a measurable improvement in memory-constrained environments where this tool is intended to run.
