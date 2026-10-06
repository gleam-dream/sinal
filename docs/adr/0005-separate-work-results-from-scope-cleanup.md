# Separate work results from scope cleanup

<a id="adr-0005"></a>

- A subscription scope acquires registrations in order and cleans up successful acquisitions in reverse order. Normal completion retains the work value beside indexed cleanup failures; catchable exceptional completion cleans up and re-raises the original class, reason and stacktrace. Cleanup-reporter failure cannot replace the work exception.
- Returning only cleanup success would discard completed business work, while ignoring cleanup would hide registrations the caller still owns. Waiting for selected callbacks to finish would add a quiescence protocol that native detach does not provide, so scope exit remains registration removal rather than callback completion.
- Native scoped cleanup is evidenced by [`0204cc7088266e97eb76f77c1b1fb8ef96d5cdb4`](https://github.com/gleam-dream/sinal/commit/0204cc7088266e97eb76f77c1b1fb8ef96d5cdb4), dated 2026-09-20; heterogeneous subscription plans and indexed results appear in [`63c7c7d90142998c65ce1dd81b1225d56efd1b19`](https://github.com/gleam-dream/sinal/commit/63c7c7d90142998c65ce1dd81b1225d56efd1b19), dated 2026-09-22. The rationale is reconstructed from the prior lifetime contract and those implementations; no separate historical approval date is known.
