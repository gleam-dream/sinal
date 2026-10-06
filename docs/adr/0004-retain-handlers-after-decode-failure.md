# Retain handlers after decode failure

<a id="adr-0004"></a>

- A malformed native map skips one typed invocation and notifies its failure observer without removing the registration. The earlier policy raised after reporting the decode failure, so one incompatible foreign occurrence or an incomplete enum list removed the subscriber and hid every later valid occurrence. Handler-returned errors and unexpected exceptions retain native removal and failure notification.
- Removing a malformed-data subscriber matched native exception removal mechanically but made payload incompatibility permanently disable observation. Silently ignoring malformed values would retain availability while removing the diagnostic needed to repair the schema; the selected rule keeps both the registration and the classified failure.
- This explicitly supersedes the decode-removal rule in oversight's earlier Sinal design. Implementation and updated oracle mapping are in [`5aef827c5b486127f7623c8819929c2cd9e52760`](https://github.com/gleam-dream/sinal/commit/5aef827c5b486127f7623c8819929c2cd9e52760), dated 2026-10-02.
