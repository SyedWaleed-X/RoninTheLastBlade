# ARCHITECTURE SPECIFICATION

## Directory Structure
- `src/server`: Server-authoritative logic (Combat validation, DataManager, Damage pipelines). Mapped to `ServerScriptService`.
- `src/shared`: Shared types, configurations, state definitions, and utility math. Mapped to `ReplicatedStorage`.
- `src/client`: Input buffering, local visual prediction, camera shake, and UI. Mapped to `StarterPlayerScripts`.

## Engineering Rules
1. Every Luau file must begin with `--!strict`.
2. All RemoteEvents must be wrapped in validation schemas.
3. Client can request actions; Server authoritatively executes damage and state transitions.
4. Zero run-time table allocations inside high-frequency `RunService.Heartbeat` loops.