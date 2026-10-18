# Document usage as compiled examples and keep oracle and benchmark references as linked docs

<a id="adr-0014"></a>

- Usage is documented by a separate package of compiled, runnable examples under `examples/usage`, one module per topic, each with a `run` function that asserts what the example does. The package depends on Sinal by path, so a library change that breaks an example fails the validation profiles that build and run it.
- The README keeps a short usage section whose snippets occur verbatim in those modules, and a test in the package root enforces that. No prose usage guide stands beside the examples, because prose cannot fail when the library changes.
- The pinned native oracle and the benchmark method stay as two reference documents, `docs/ORACLE.md` and `docs/BENCHMARKS.md`, that link each other, the verification design, the relevant decisions and `AGENTS.md`. They hold information that is neither a present-tense design rule nor a decision: source pins and checksums, the case-by-case mapping, the retained run table and its environment. The design states the rules and links the documents instead of copying their tables.
- Folding the case mapping and the run table into the design would have made the design carry evidence that changes with each run, and deleting them would have lost the pin that makes the oracle comparison reproducible.
- The change supersedes the earlier choice to fold the usage examples and both references into the README and the design only. The package keeps no changelog, as ADR 0013 records.
