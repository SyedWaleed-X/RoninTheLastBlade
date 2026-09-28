# ARCHITECTURE SPECIFICATION

## Directory Structure
## Directory Structure
- `src/server/ServerScriptService`: Server-authoritative logic. Mapped to `ServerScriptService`.
- `src/shared/ReplicatedStorage`: Shared types, configurations, state definitions, and utility math. Mapped to `ReplicatedStorage`.
- `src/client/StarterPlayerScripts`: Input buffering, local visual prediction, camera shake, and UI. Mapped to `StarterPlayerScripts`.

## Engineering Rules
1. Every Luau file must begin with `--!strict`.
2. All RemoteEvents must be wrapped in validation schemas.
3. Client can request actions; Server authoritatively executes damage and state transitions.
4. Zero run-time table allocations inside high-frequency `RunService.Heartbeat` loops.