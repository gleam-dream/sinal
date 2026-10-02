-module(sinal_ffi).

-export([
    empty_map/0,
    map_put/3,
    map_lookup/2,
    is_native_map/1,
    is_missing_marker/1,
    telemetry_attach_many/3,
    telemetry_detach/1,
    telemetry_execute/3,
    handle/4,
    raise_callback_failure/1,
    telemetry_span/3,
    convert_native_time/2,
    unique_handler_id/0,
    unique_correlation/0,
    event_parts/1,
    identity/1,
    is_decoding/0,
    decoding/1,
    log_warning/1
]).

identity(X) ->
    X.

%% True while this process runs sinal/fields.decode. A record built during
%% a decode leaves its encoding plan unbuilt, because only its decoder runs.
is_decoding() ->
    get(sinal_fields_decoding) =:= true.

decoding(Decode) ->
    case get(sinal_fields_decoding) of
        true ->
            Decode();
        _ ->
            put(sinal_fields_decoding, true),
            try
                Decode()
            after
                erase(sinal_fields_decoding)
            end
    end.

empty_map() ->
    #{}.

map_put(Map, Key, Value) ->
    Map#{Key => Value}.

map_lookup(Map, Key) when is_map(Map) ->
    case Map of
        #{Key := Value} -> {present, Value};
        _ -> absent
    end;
map_lookup(_, _) ->
    not_a_map.

is_native_map(Term) ->
    is_map(Term).

is_missing_marker(nil) -> true;
is_missing_marker(undefined) -> true;
is_missing_marker(_) -> false.

%% Every handler is attached as this exported function, with the typed
%% Gleam callback as its config. An exported capture keeps telemetry on its
%% fast path and stops it from logging a "local function" warning for each
%% attachment.
handle(EventName, Measurements, Metadata, Callback) ->
    Callback(EventName, Measurements, Metadata).

telemetry_attach_many(HandlerId, EventNames, Callback) ->
    ensure_telemetry_started(),
    case telemetry:attach_many(HandlerId, EventNames, fun ?MODULE:handle/4, Callback) of
        ok -> {ok, nil};
        {error, already_exists} -> {error, nil}
    end.

%% The handler table process is registered under its module name. When it is
%% missing, start the telemetry application (and anything it needs) instead
%% of letting the attach call exit with noproc.
ensure_telemetry_started() ->
    case whereis(telemetry_handler_table) of
        undefined ->
            case application:ensure_all_started(telemetry) of
                {ok, _} -> ok;
                {error, Reason} -> erlang:error({sinal_telemetry_not_started, Reason})
            end;
        _ ->
            ok
    end.

telemetry_detach(HandlerId) ->
    case whereis(telemetry_handler_table) of
        undefined ->
            {error, nil};
        _ ->
            case telemetry:detach(HandlerId) of
                ok -> {ok, nil};
                {error, not_found} -> {error, nil}
            end
    end.

telemetry_execute(EventName, Measurements, Metadata) ->
    telemetry:execute(EventName, Measurements, Metadata),
    nil.

raise_callback_failure(Reason) ->
    erlang:error({sinal_callback_failure, Reason}).

telemetry_span(EventPrefix, StartMetadata, SpanFun) ->
    telemetry:span(EventPrefix, StartMetadata, SpanFun).

convert_native_time(Value, Unit) -> erlang:convert_time_unit(Value, native, Unit).

unique_handler_id() ->
    {sinal_handler, erlang:unique_integer([positive])}.

%% 128 random bits as 32 lowercase hex characters: the shape of a W3C trace
%% id. All zeros is not a valid trace id, so it is redrawn.
unique_correlation() ->
    case crypto:strong_rand_bytes(16) of
        <<0:128>> -> unique_correlation();
        Bytes -> binary:encode_hex(Bytes, lowercase)
    end.

%% The name and codecs of a `sinal.Event`, for the forwarder, which encodes
%% an event without going through `sinal.emit`'s routes.
event_parts({event, Name, Measurements, Metadata}) ->
    {Name, Measurements, Metadata}.

log_warning(Message) ->
    logger:warning("~ts", [Message], #{domain => [sinal]}),
    nil.
