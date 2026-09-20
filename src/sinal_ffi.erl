-module(sinal_ffi).

-export([
    empty_map/0,
    map_from_pair/2,
    map_get/2,
    map_merge/2,
    is_native_map/1,
    telemetry_attach_many/4,
    telemetry_detach/1,
    telemetry_execute/3,
    raise_callback_failure/1,
    identity/1
]).

identity(X) ->
    X.

empty_map() ->
    #{}.

map_from_pair(Key, Value) ->
    #{Key => Value}.

map_get(Map, Key) when is_map(Map) ->
    case maps:find(Key, Map) of
        {ok, Value} -> {ok, Value};
        error -> {error, nil}
    end;
map_get(_, _) ->
    {error, nil}.

map_merge(MapA, MapB) when is_map(MapA), is_map(MapB) ->
    maps:merge(MapA, MapB);
map_merge(_, _) ->
    #{}.

is_native_map(Term) ->
    is_map(Term).

telemetry_attach_many(HandlerId, EventNames, Fun, Config) ->
    case telemetry:attach_many(HandlerId, EventNames, Fun, Config) of
        ok -> {ok, nil};
        {error, already_exists} -> {error, native_already_exists};
        {error, Other} -> {error, {native_attach_other, Other}}
    end.

telemetry_detach(HandlerId) ->
    case telemetry:detach(HandlerId) of
        ok -> {ok, nil};
        {error, not_found} -> {error, native_not_found};
        {error, Other} -> {error, {native_detach_other, Other}}
    end.

telemetry_execute(EventName, Measurements, Metadata) ->
    telemetry:execute(EventName, Measurements, Metadata).

raise_callback_failure(Reason) ->
    erlang:error({sinal_callback_failure, Reason}).
