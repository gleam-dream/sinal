# Wave 4 Capabilities and Tooling Probes

This report records the pre-implementation environment, toolchain, search/URL citation, and oversight-access probes for the Sinal Wave 4 initial release completion scope.

## 1. Repository Baseline and Branch

- **Repository:** `/code/gleam-dream/sinal`
- **Branch:** `master`
- **Starting HEAD:** `13105a1777d01d6e1904ae624409ff2f25c739aa`
- **Working tree status:** Clean at start of Wave 4 execution.

## 2. Authoritative Oversight Files Read

The following reference documents from `/code/gleam-dream/oversight` were read prior to editing:

1. `docs/implementation/sinal-blueprint/wave-4-work-order.md`: Initial release completion work order, authorizing the resolution of all Review 3 findings, operational race/boundary coverage, bounded stress harness, microbenchmarks, runnable examples/docs, and nonpublishing package dry run.
2. `docs/implementation/sinal-blueprint/review-3.md`: P1 findings on original stack origin fidelity, failure event name and handler configuration assertion, real barrier-synchronized detach race, and behavioral checks on native span-owned values.
3. `sinal-design.md`: Authoritative architecture for Sinal, specifying direct BEAM `:telemetry` 1.4.2 binding, synchronous execution semantics, non-quiescent detach, and honest error/exception propagation.
4. `PUBLIC-API.md`: Frozen public API facade for `sinal`.

**Key architectural boundaries confirmed:**

- Oversight remains strictly read-only; all edits are confined to `/code/gleam-dream/sinal`.
- No speculative registry introspection APIs or metrics/OpenTelemetry APIs are to be added.
- All execution must be synchronous, awaiting child processes without background jobs.

## 3. Language Intelligence and Compiler Probes

- **Configured LSP bridge (`agent-lsp`) probe:**
  - **Executable path:** `/etc/profiles/per-user/edgar/bin/agent-lsp` (invoked directly via absolute path).
  - **Configuration:** `gleam:gleam,lsp` with `PATH` prepended with Nix Gleam compiler (`/nix/store/ww32xyvhifsys9lwsmwgxc36fy9gvy6i-gleam-1.18.1/bin`), avoiding shell wrapper banners that corrupt MCP stdio newline framing.
  - **MCP Handshake:** MCP `initialize` and `notifications/initialized` succeeded with protocol version `2024-11-05`, reporting server `agent-lsp` version `dev`.
  - **Real Source Probes:**
    - Called `list_symbols` with `"format": "outline"` on `/code/gleam-dream/sinal/src/sinal.gleam`, returning the complete symbol outline (including `version`, `event`, `trusted_event`, `handler`, `with_attachments`, etc.).
    - Called `list_symbols` with `"format": "outline"` on `/code/gleam-dream/sinal/src/sinal/span.gleam`, extracting symbols (`event_prefix`, `trusted_prefix`, `define_span`, `run_span`, etc.).
- **Compiler Authority:**
  - `nix develop --command gleam check` verified as the authoritative Gleam type checker.
  - `nix develop --command gleam test` verified as the authoritative test runner.

## 4. Web Search and Official-Source Citations

- Search and URL retrieval capabilities were verified in Wave 3:
  - `search_web` query `"erlang telemetry span/3 telemetry 1.4.2"` retrieved official Hex documentation and source citations.
  - `read_url_content` fetched frozen `:telemetry` 1.4.2 HTML specification from `https://hexdocs.pm/telemetry/1.4.2/telemetry.html#span/3`.
  - Frozen source commit `7baf8085e406d5ae9e43b284d7c866742ae04b28` (`v1.4.2`) remains the pinned upstream oracle as cataloged in `test/oracle/telemetry-1.4.2.md`.

## 5. Oversight-File Access Confirmation

Confirmed read access to all relevant files under `/code/gleam-dream/oversight`. Oversight is strictly read-only and preserved untouched.
