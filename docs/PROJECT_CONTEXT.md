# RONIN — THE LAST BLADE
## Project Specification & Technical Context

### Game Overview
High-skill, reaction-based Japanese sword combat game inspired by Sekiro and modern Roblox combat titles (Untitled Boxing Game, Blade Ball).

### Core Pillars
1. **Deterministic State Machine:** Strict action locking (Windup, Active, Recovery, Blocking, Parrying).
2. **Micro-Frame Reaction Deflect:** 133ms parry window with visual sparks and posture damage reflection.
3. **Dual Health & Posture System:** Depleting posture triggers vulnerable kneeling executions.
4. **Decoupled Architecture:** Strict client-server boundaries, zero trust on client physics.

### Technical Standards
- **Language:** Luau with strict typechecking (`--!strict`).
- **Sync Pipeline:** Roblox Studio Native Script Sync (`src/server`, `src/client`, `src/shared`).
- **AI Agent Bridge:** Roblox Studio MCP Server.