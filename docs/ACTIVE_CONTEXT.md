# RONIN: ACTIVE CONTEXT RELAY
*Last Updated: End of Day 3*

## 1. Project Phase
- Completed: Day 1 (Setup, MCP, Git), Day 2 (FSM Engine & Debug HUD), Day 3 (Input Buffering & Telemetry).
- Next Up: Day 4 (3-Hit Attack Chain Mechanics, Frame Data Windows, & Root Motion Lunges).

## 2. Live System Registry
- `src/shared/ReplicatedStorage/CombatTypes.luau` (Authoritative Combat States & Type Definitions)
- `src/shared/ReplicatedStorage/StateMachine.luau` (Deterministic FSM with Interruption Matrix)
- `src/client/StarterPlayerScripts/CombatStateBus.luau` (Client-side decoupled state event bus)
- `src/client/StarterPlayerScripts/CombatController.local.luau` (Character lifecycle binder & consumption loop)
- `src/client/StarterPlayerScripts/InputBuffer.luau` (200ms sliding FIFO queue with os.clock precision)
- `src/client/StarterPlayerScripts/InputBinder.local.luau` (ContextActionService mouse/keyboard/touch sink)
- `src/client/StarterPlayerScripts/CombatDebugUI.local.luau` (State badge + live input telemetry HUD)

## 3. Active Invariants
1. All client inputs are queued into `InputBuffer` (200ms window); consumed on entering `Idle`.
2. Entering `Stunned` flushes the buffer instantly (`InputBuffer.Clear()`).
3. Priority Matrix rejects illegal actions (e.g. cannot Attack while in Stunned or Recovery).