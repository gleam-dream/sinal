-module(sinal_forwarder_ffi).

-export([
    publish_target/2,
    find_target/1,
    new_counters/0,
    shared_counters/1,
    add_get/3,
    exchange/3,
    decrement_floor/2,
    put_route/2,
    erase_route/1,
    find_route/1
]).

%% Three lock-free signed slots used for diagnostic counts or local admission.
%% Diagnostic slots are shared by every `Forwarder` of one name, across
%% every incarnation of the process that drains them:
%%   index 1 - in-flight Execute messages sent but not yet drained (`lost` on
%%             a fresh incarnation is this slot's leftover value).
%%   index 2 - capacity drops since the last drain (`rejected`).
%%   index 3 - sends that found no running incarnation since the last drain
%%             (`unavailable`).
new_counters() ->
    atomics:new(3, [{signed, true}]).

%% The diagnostic counters of a forwarder name, created on first use and
%% kept in `persistent_term` for the life of the node, so that every
%% `Forwarder` value built from one name shares them. Storing a new key does
%% not trigger the global scan that replacing or erasing one does.
shared_counters(Name) ->
    Key = {sinal_forwarder_counters, Name},
    case persistent_term:get(Key, undefined) of
        undefined ->
            global:trans(
                {Key, self()},
                fun() ->
                    case persistent_term:get(Key, undefined) of
                        undefined ->
                            Counters = new_counters(),
                            persistent_term:put(Key, Counters),
                            Counters;
                        Counters ->
                            Counters
                    end
                end,
                [node()]
            );
        Counters ->
            Counters
    end.

add_get(Ref, Index, Delta) ->
    atomics:add_get(Ref, Index, Delta).

%% Atomically reads a slot and resets it to Value, returning the prior
%% reading. Used to drain a counter exactly once per cycle.
exchange(Ref, Index, Value) ->
    atomics:exchange(Ref, Index, Value).

%% Floored decrement is also used by best-effort diagnostic counters that
%% may be drained across a restart. Admission uses separate counters belonging
%% exclusively to one incarnation; those are never reset while it is alive.
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

%% The node's routes live in one `persistent_term` value: a list of
%% {Prefix, Send} sorted longest prefix first, where Send hands an encoded
%% event to the route's forwarder, so a lookup on the emit
%% path takes no lock, copies nothing, allocates nothing, and returns at once
%% when nothing is routed. Writing the value is expensive (it can trigger a
%% global scan of processes still referencing the old one), which is why
%% routes are application setup, not something to change per event. Writers
%% serialise through a node-local `global` lock so concurrent `route` and
%% `unroute` calls never lose each other's change.
-define(ROUTES, sinal_forwarder_routes).

put_route(Prefix, Send) ->
    update_routes(fun(Routes) ->
        [{Prefix, Send} | lists:keydelete(Prefix, 1, Routes)]
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

%% Finds the send function of the longest routed prefix of Name.
find_route(Name) ->
    find_route(Name, persistent_term:get(?ROUTES, [])).

find_route(_Name, []) ->
    {error, nil};
find_route(Name, [{Prefix, Send} | Rest]) ->
    case lists:prefix(Prefix, Name) of
        true -> {ok, Send};
        false -> find_route(Name, Rest)
    end.

%% The table belongs to this actor incarnation and disappears on its death.
%% Its single typed row couples a direct subject to that incarnation's slots.
%% Concurrent producers cannot see the target before it is fully initialised.
publish_target(Name, Target) ->
    try
        Table = ets:new(Name, [named_table, protected, {read_concurrency, true}]),
        true = ets:insert(Table, {target, Target}),
        {ok, nil}
    catch error:badarg -> {error, nil}
    end.

find_target(Name) ->
    try ets:lookup(Name, target) of
        [{target, Target}] -> {ok, Target};
        [] -> {error, nil}
    catch error:badarg -> {error, nil}
    end.
