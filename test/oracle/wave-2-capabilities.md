# Wave 2 Capabilities and Tooling Probes

This report records the required pre-implementation environment, toolchain, search, and official-source probes for the Sinal Wave 2 scope.

## 1. Repository Baseline and Branch

- **Repository:** `/code/gleam-dream/sinal`
- **Branch:** `master`
- **Starting HEAD:** `35c83e11e1d58f1ee9e3185112842e7ab75c666e`
- **Working tree status:** Clean prior to recording this probe file.

## 2. Authoritative Oversight Files Read

The following reference documents from `/code/gleam-dream/oversight` were read prior to editing:

1. `docs/implementation/sinal-blueprint/wave-2-work-order.md`: Authorizing Wave 2 scope, milestones, and acceptance criteria.
2. `docs/implementation/sinal-blueprint/review-1.md`: Record of checkpoint review findings and accepted architectural direction.
3. `sinal-design.md`: Core system architecture, native BEAM telemetry runtime ownership, atom safety, map boundaries, and lifecycle contracts.
4. `PUBLIC-API.md`: Public API freeze and boundaries for the `sinal` package facade.

**Key constraint affecting implementation:**
Observations report completed package transitions and never control them. Sinal is a typed facade over the global native `:telemetry` registry, not an actor/event bus and not a JSON codec library. Event names must be trusted atom lists and measurement/metadata terms must cross the FFI as native BEAM maps without intermediate JSON serialization or runtime atom creation.

## 3. Language Intelligence and Compiler Probes

- **`agent-lsp` probe:** Configured bridge probed via absolute executable `/etc/profiles/per-user/edgar/bin/agent-lsp gleam:gleam,lsp` with Nix Gleam binary in `PATH`. MCP handshake succeeded, and calling `list_symbols` on `src/sinal.gleam` successfully resolved 29 language symbols.
- **Built-in `gleam lsp` probe:** Probed via stdio initialize request (`gleam lsp`); returns `ProtocolError("disconnected channel")` on non-interactive pipes as expected.
- **Compiler fallback:** Configured project compiler `nix develop --command gleam check` probed and confirmed working synchronously as the authoritative type checker and diagnostic authority.

## 4. Web Search and URL Fetch / Browser Inventory

- **Web search capability:** Available and verified via `search_web`.
  - Probe query: `"beam telemetry erlang github"`
  - Result: Returned live search summary and documentation citations from `beam-telemetry/telemetry`.
- **URL fetch capability:** Available and verified via `read_url_content`.
  - Probe URL: `https://github.com/beam-telemetry/telemetry/blob/7baf8085e406d5ae9e43b284d7c866742ae04b28/src/telemetry.erl`
  - Result: Successfully fetched and verified the pinned 1.4.2 telemetry Erlang source at commit `7baf8085e406d5ae9e43b284d7c866742ae04b28`.
