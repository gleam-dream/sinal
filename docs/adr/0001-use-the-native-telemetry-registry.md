# Use the native telemetry registry

<a id="adr-0001"></a>

- Sinal uses the shared native `:telemetry` registry rather than creating an actor for each event. The native registry preserves caller process identity, synchronous dispatch, native names and maps, and interoperability with Erlang and Elixir handlers. An actor per event would alter those observable contracts.
- Reconstructed from oversight's original native-facade decision and Sinal implementation commits [`0204cc7088266e97eb76f77c1b1fb8ef96d5cdb4`](https://github.com/gleam-dream/sinal/commit/0204cc7088266e97eb76f77c1b1fb8ef96d5cdb4) and [`13105a1777d01d6e1904ae624409ff2f25c739aa`](https://github.com/gleam-dream/sinal/commit/13105a1777d01d6e1904ae624409ff2f25c739aa), both dated 2026-09-20. The date of the original architectural choice and its separate approval record are unknown.
- A mandatory JSON representation was also excluded. Native references, exception reasons, stacktraces and arbitrary caller-defined BEAM values cannot be faithfully represented by a compulsory JSON conversion.
