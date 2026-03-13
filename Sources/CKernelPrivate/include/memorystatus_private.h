// memorystatus_private.h
// Private kernel API declarations for memorystatus_control and related types.
//
// These APIs are not exposed in public SDK headers but are stable interfaces
// used by system tools and daemons. The structures and constants are defined
// in the XNU kernel source (bsd/sys/kern_memorystatus.h).

#ifndef MEMORYSTATUS_PRIVATE_H
#define MEMORYSTATUS_PRIVATE_H

#include <stdint.h>
#include <sys/types.h>

// memorystatus_control commands
#define MEMORYSTATUS_CMD_GET_PRIORITY_LIST              1
#define MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES        2
#define MEMORYSTATUS_CMD_GET_JETSAM_SNAPSHOT             3
#define MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK      5
#define MEMORYSTATUS_CMD_CONVERT_MEMLIMIT_MB            10

// Jetsam priority bands (subset used for filtering)
#define JETSAM_PRIORITY_IDLE            0
#define JETSAM_PRIORITY_DEFAULT        10

// memorystatus_priority_entry — layout from XNU bsd/sys/kern_memorystatus.h.
// All fields must be present for correct stride when iterating the kernel buffer.
// Verified against apple/darwin-xnu main branch kern_memorystatus.h.
// CRITICAL: user_data is uint64_t in XNU, not int32_t — wrong size causes
// stride mismatch and corrupts all decoded entries after the first.
typedef struct memorystatus_priority_entry {
    pid_t pid;
    int32_t priority;
    uint64_t user_data; // opaque, set by memorystatus_control (64-bit!)
    int32_t limit;      // memory limit in MB (-1 = no limit)
    uint32_t state;     // flags (dirty, idle exit eligible, etc.)
} memorystatus_priority_entry_t;

// memorystatus_control — the main kernel interface for jetsam operations.
// Requires root for most commands.
int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags,
                         void *buffer, size_t buffersize);

#endif // MEMORYSTATUS_PRIVATE_H
