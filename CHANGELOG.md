# Changelog

## Unreleased — initial release

- Typed native telemetry events, field codecs, subscriptions, scopes and spans retain caller-owned values and native handler semantics.
- Applications can select supervised bounded forwarding, prefix routes and shared correlation without transferring business authority to observation handlers.
- The [README](README.md) documents current usage. The [design layer](docs/design/design.typ) records behavior, lifecycle limits and unresolved contracts; [ADRs](docs/adr/0001-use-the-native-telemetry-registry.md) record the pre-release decisions.

The package version remains unchanged pending a release decision. The unpublished construction diary has been consolidated into the design layer and ADRs; it is not a migration contract for a published release.
