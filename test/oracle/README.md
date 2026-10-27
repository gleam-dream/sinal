# Native telemetry oracle

[![CI](https://github.com/gleam-dream/sinal/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/sinal/actions/workflows/ci.yml)
[![sinal on Hex](https://img.shields.io/hexpm/v/sinal?label=Hex%3A%20sinal)](https://hex.pm/packages/sinal)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

Pinned reference for the native boundary tests: telemetry 1.4.2, tag `v1.4.2`, revision `7baf8085e406d5ae9e43b284d7c866742ae04b28`.

The sources, case mapping, classification, deliberate differences and limits are in [docs/ORACLE.md](../../docs/ORACLE.md). Recheck the upstream suite from a checkout at that revision:

```sh
cd build/upstream/telemetry && rebar3 ct
```
