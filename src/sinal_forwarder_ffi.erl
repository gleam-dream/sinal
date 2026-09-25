-module(sinal_forwarder_ffi).

-export([
    new_counters/0,
    add_get/3,
    exchange/3,
    decrement_floor/2,
    try_send/1
]).

%% Two lock-free signed slots shared across a forwarder's lifetime, including
%% across a supervisor restart of the process that drains them:
%%   index 1 - in-flight Execute messages sent but not yet drained (`lost` on
%%             a fresh incarnation is this slot's leftover value).
%%   index 2 - accumulated drop count since the last drain (`rejected`).
new_counters() ->
    atomics:new(2, [{signed, true}]).

add_get(Ref, Index, Delta) ->
    atomics:add_get(Ref, Index, Delta).

%% Atomically reads a slot and resets it to Value, returning the prior
%% reading. Used to drain a counter exactly once per cycle.
exchange(Ref, Index, Value) ->
    atomics:exchange(Ref, Index, Value).

%% Decrements a slot but never past 0, via a compare-and-swap retry loop.
%%
%% A restarting forwarder is registered under its name before its own
%% initialiser runs (an `actor.start`/`gleam_otp` ordering, not something
%% this module controls), so a concurrent `emit` can resolve the name to the
%% new incarnation and queue an Execute message before that incarnation has
%% drained the slot it inherited from the one that crashed. The queued
%% message is real and will still be processed, but the drain can already
%% have counted it (or count towards it) as `lost`. Without a floor, the
%% later post-execute decrement for that same message would then take the
%% freshly-reset counter negative, permanently and silently raising the
%% effective capacity for the rest of that incarnation's life. Flooring at 0
%% cannot make the counter under-count a message still genuinely in flight
%% (the increment that admitted it already happened), so it only ever
%% removes a spurious negative, never a real one.
decrement_floor(Ref, Index) ->
    decrement_floor(Ref, Index, atomics:get(Ref, Index)).

decrement_floor(_Ref, _Index, Current) when Current =< 0 ->
    0;
decrement_floor(Ref, Index, Current) ->
    Next = Current - 1,
    case atomics:compare_exchange(Ref, Index, Current, Next) of
        ok -> Next;
        Actual -> decrement_floor(Ref, Index, Actual)
    end.

%% Runs Thunk, rescuing any raised class so a send to an unregistered or
%% unavailable named process is reported rather than propagated. `gleam_erlang`
%% panics when `process.send/2` targets a named subject with no registered
%% process, so this is the only safe way to send best-effort to a forwarder
%% that may not be running.
try_send(Thunk) ->
    try Thunk() of
        _ -> {ok, nil}
    catch
        _:_ -> {error, nil}
    end.
