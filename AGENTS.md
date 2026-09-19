# Agent Instructions

## About this repo

`sinal` — A strongly-typed take on Erlang :telemetry, built for Gleam's generics instead of dynamic maps and atoms.

Ports/wraps: :telemetry (beam-telemetry/telemetry). Design: [gleam-dream/oversight](https://github.com/gleam-dream/oversight)/sinal-design.md.

## Tooling

- `nix develop` (or direnv): dev shell with `gleam`, Erlang/OTP 28, `rebar3`, `lefthook`.
- `nix fmt`: formats the whole repo via treefmt (`gleam format`, `nixfmt`, `prettier`).
- `lefthook`: pre-commit hook formats staged files and re-stages them.
- `nix flake check`: fails iff the tree is not formatted (plus any existing checks).
- `gleam test`: runs the test suite.
