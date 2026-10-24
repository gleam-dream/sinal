# Native telemetry oracle

Pinned reference for the native boundary tests: telemetry 1.4.2, tag `v1.4.2`, revision `7baf8085e406d5ae9e43b284d7c866742ae04b28`.

The sources, case mapping, classification, deliberate differences and limits are in [docs/ORACLE.md](../../docs/ORACLE.md). Recheck the upstream suite from a checkout at that revision:

```sh
cd build/upstream/telemetry && rebar3 ct
```
