-module(sinal_ffi).

-export([empty_map/0, map_from_pair/2, map_get/2, map_merge/2, is_native_map/1]).

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
