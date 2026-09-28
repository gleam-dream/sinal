-module(sinal_forwarder_ffi).

-export([
    new_counters/0,
    add_get/3,
    exchange/3,
    decrement_floor/2,
    try_send/1,
    put_route/2,
    erase_route/1,
    find_route/1
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

%% The node's routes live in one `persistent_term` value: a list of
%% {Prefix, Forwarder} sorted longest prefix first, so a lookup on the emit
%% path takes no lock, copies nothing, allocates nothing, and returns at once
%% when nothing is routed. Writing the value is expensive (it can trigger a
%% global scan of processes still referencing the old one), which is why
%% routes are application setup, not something to change per event. Writers
%% serialise through a node-local `global` lock so concurrent `route` and
%% `unroute` calls never lose each other's change.
-define(ROUTES, sinal_forwarder_routes).

put_route(Prefix, Forwarder) ->
    update_routes(fun(Routes) ->
        [{Prefix, Forwarder} | lists:keydelete(Prefix, 1, Routes)]
    end).

erase_route(Prefix) ->
    update_routes(fun(Routes) -> lists:keydelete(Prefix, 1, Routes) end).

update_routes(Change) ->
    global:trans(
        {?ROUTES, self()},
        fun() ->
            Routes = lists:sort(
                fun({A, _}, {B, _}) -> length(A) >= length(B) end,
                Change(persistent_term:get(?ROUTES, []))
            ),
            case Routes of
                [] -> persistent_term:erase(?ROUTES);
                _ -> persistent_term:put(?ROUTES, Routes)
            end
        end,
        [node()]
    ),
    nil.

%% Finds the forwarder of the longest routed prefix of Name.
find_route(Name) ->
    find_route(Name, persistent_term:get(?ROUTES, [])).

find_route(_Name, []) ->
    {error, nil};
find_route(Name, [{Prefix, Forwarder} | Rest]) ->
    case lists:prefix(Prefix, Name) of
        true -> {ok, Forwarder};
        false -> find_route(Name, Rest)
    end.
