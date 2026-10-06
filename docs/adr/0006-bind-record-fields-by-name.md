# Bind record fields by name

<a id="adr-0006"></a>

- A record codec binds each decoded field by name in a `fields.include` block ending in `fields.success`. The earlier positional builder could silently swap two fields with the same type and needed a first-getter annotation. Named binding removes the silent swap and uses the same caller shape as Blueprint's record builder without introducing a dependency on Blueprint.
- Retaining positional application made constructor order a hidden correctness condition. An external macro or generated builder would add build machinery without removing the native field contract; the selected design uses ordinary Gleam closures and preserves encoded keys and declaration-order decoding.
- The encoding plan is computed using placeholder values at definition, so the builder and custom decoders must remain free of effects and value-dependent field selection. Implementation evidence is [`5e8bee30a167fc6461ab7dd28d87fc3fa881d89e`](https://github.com/gleam-dream/sinal/commit/5e8bee30a167fc6461ab7dd28d87fc3fa881d89e), dated 2026-10-02.
