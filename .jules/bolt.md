## 2024-05-24 - Actor Serialization of TaskGroup Subtasks
**Learning:** In Swift, when an actor creates a TaskGroup and its subtasks call an async method defined on the same actor without nonisolated, the subtasks are serialized on the actor's executor, defeating the purpose of the TaskGroup for parallelism.
**Action:** Always mark intensive, state-independent methods within an actor (like file system scanners) as nonisolated to ensure they can run concurrently on the global executor when spawned from a TaskGroup.
