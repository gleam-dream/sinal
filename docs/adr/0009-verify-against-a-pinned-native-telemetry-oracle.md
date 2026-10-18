# Verify the native boundary against a pinned telemetry oracle

<a id="adr-0009"></a>

- Sinal compares its native boundary with telemetry 1.4.2 at upstream revision `7baf8085e406d5ae9e43b284d7c866742ae04b28`. A pinned release gives each mapped case an expected behavior that does not move with the dependency range, which admits later 1.x releases.
- The mapping states semantic equivalence case by case and lists each adaptation and exclusion. The decode-retention rule of ADR 0004 is an adaptation, and the full upstream matrix under both `ets` and `persisted` registry groups is not claimed.
- Porting every upstream assertion literally would test the upstream suite rather than Sinal's typed boundary. Running no differential check would leave native interoperability to inspection.
- The original harvest ran `rebar3 ct` in an upstream checkout and passed all 42 upstream cases. That result is provenance for the pin; a fresh harvest records its own checkout, dependencies and result.
- The design states the pin, the disposition rules and the adaptations. The case-by-case mapping and exclusion table live in [docs/ORACLE.md](../ORACLE.md), which also says how to recheck the pin and links the matching [benchmarks](../BENCHMARKS.md); `test/oracle/README.md` is a short run guide that points there.
