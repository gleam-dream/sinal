# Isolate admission by forwarder incarnation

<a id="adr-0008"></a>

- A running forwarder publishes its direct event subject, capacity and fresh admission counters as one incarnation-owned target. A delayed producer retains that target and therefore cannot send into a replacement process or change its admission count. Separate name-wide diagnostic counters preserve refused and estimated lost counts across restarts without becoming admission authority.
- Reusing name-resolved destinations with reset shared admission counters allowed delayed work from one lifetime to enter another and invalidate the capacity bound. Using only incarnation-local diagnostics would keep admission safe but lose unavailable-drop evidence during restarts; the selected split retains both properties while keeping the lost count explicitly approximate.
- Implementation evidence is [`8acec4507f23daa7f49c40cc7d39816a5a4c3d1d`](https://github.com/gleam-dream/sinal/commit/8acec4507f23daa7f49c40cc7d39816a5a4c3d1d), dated 2026-10-01. Deterministic startup, delayed-sender and delayed-drop probes remain executable in `dev/check_forwarder.py`; no drain or delivery acknowledgement was added.
