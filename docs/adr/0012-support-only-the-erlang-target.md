# Support only the Erlang target

<a id="adr-0012"></a>

- Sinal targets Erlang/BEAM because its boundary uses native telemetry, maps, references, OTP processes, ETS, atomics and `persistent_term`. No JavaScript port is promised.
- A JavaScript target would need a different registry, process model and exception semantics, which would remove the native interoperability that motivates the package (ADR 0001).
- The package requires Gleam 1.18 or newer and admits telemetry 1.4.2 through later 1.x releases. The flake lock pins the toolchain that the gate exercises, so support for an untested Gleam or OTP release is not claimed.
