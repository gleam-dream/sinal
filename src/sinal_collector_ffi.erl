-module(sinal_collector_ffi).

-export([create/2, record/2, entries/1, recorded/1]).

%% The collector's entries live in a public named ETS table owned by the
%% collector process, so the table disappears with that process. Row
%% `meta` holds the capacity and a one-slot atomics sequence. Entry rows
%% are `{Slot, Sequence, Entry}` with Slot = (Sequence - 1) rem Capacity,
%% so the table never holds more than Capacity entries.
create(Name, Capacity) ->
    try
        Table = ets:new(Name, [named_table, public, set, {write_concurrency, true}]),
        true = ets:insert(Table, {meta, Capacity, atomics:new(1, [{signed, false}])}),
        {ok, nil}
    catch
        error:badarg -> {error, nil}
    end.

%% Writes Entry over the oldest slot. Runs in the calling process and never
%% raises: without a running collector the entry is discarded. The table is
%% resolved once, so the read and the write reach the same incarnation: a
%% deleted table's identifier stays invalid even when a restarted collector
%% reuses the name, and the write is then discarded.
record(Name, Entry) ->
    try
        Table = ets:whereis(Name),
        [{meta, Capacity, Sequence}] = ets:lookup(Table, meta),
        N = atomics:add_get(Sequence, 1, 1),
        true = ets:insert(Table, {(N - 1) rem Capacity, N, Entry}),
        nil
    catch
        error:_ -> nil
    end.

%% The retained entries, oldest first.
entries(Name) ->
    try ets:tab2list(Name) of
        Rows ->
            [Entry || {_, _, Entry} <- lists:keysort(2, [Row || {Slot, _, _} = Row <- Rows, is_integer(Slot)])]
    catch
        error:badarg -> []
    end.

%% How many entries this incarnation was handed, retained or not.
recorded(Name) ->
    try ets:lookup(Name, meta) of
        [{meta, _, Sequence}] -> atomics:get(Sequence, 1);
        [] -> 0
    catch
        error:badarg -> 0
    end.
