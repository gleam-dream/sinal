# Let applications select forwarding routes

<a id="adr-0003"></a>

- Libraries emit through one route-aware `sinal.emit` operation. Applications choose event-name prefixes for a supervised bounded forwarder, while packages that own a specific forwarder use `forwarder.emit` and retain its typed refusal. A routed refusal never falls back to synchronous delivery because fallback would reintroduce the blocked-emitter failure the route is intended to prevent.
- Keeping separate routed and ordinary library emitters required every producer to opt into an application decision. Making every event asynchronous would instead remove the native synchronous contract and require default process ownership without application consent.
- The bounded forwarder first appears in [`355617c4d70dd9872cf3567066d36299dd4e3d30`](https://github.com/gleam-dream/sinal/commit/355617c4d70dd9872cf3567066d36299dd4e3d30), dated 2026-09-25; prefix routing appears in [`608944aa4430c5314bcd5f7716b3d6baafed4a8c`](https://github.com/gleam-dream/sinal/commit/608944aa4430c5314bcd5f7716b3d6baafed4a8c), dated 2026-09-27. [`1ff1c18ba52f91407269f5e4f51a8bc8e1e5ffda`](https://github.com/gleam-dream/sinal/commit/1ff1c18ba52f91407269f5e4f51a8bc8e1e5ffda), dated 2026-10-02, makes the ordinary emitter follow routes and supplies the default capacity of 1,024.
