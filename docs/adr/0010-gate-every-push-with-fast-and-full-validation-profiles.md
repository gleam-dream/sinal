# Gate every push with fast and full validation profiles

<a id="adr-0010"></a>

- One gate script (`dev/gate.py`) owns the `fast`, `full` and `benchmark` profiles that local runs and CI share. A single owner prevents local checks and CI from drifting into different definitions of passing.
- Native Erlang compiles independently with `erlc -Werror` because Gleam's `--warnings-as-errors` does not promote native Erlang warnings to failures. Gate controls prove the check fails on an unused variable.
- The gate accepts exactly one nonempty successful Gleeunit summary, because an empty or ambiguous summary can mask a test run that executed nothing.
- CI runs `full` on every push and pull request, and its final status job accepts only a successful validation job so cancellation and skipping cannot pass. Raw logs and `summary.json` are retained for 14 days even on failure.
- The benchmark profile runs in a separate weekly workflow with 30-day retention, because its observations carry no threshold and must not decide the required status.
- A fast-only gate would skip races and the design gate; running `full` locally on every change would slow iteration. The two profiles split those costs.
