-module(sinal_ffi).

-export([
    empty_map/0,
    map_put/3,
    map_lookup/2,
    is_native_map/1,
    is_missing_marker/1,
    telemetry_attach_many/5,
    new_token/0,
    telemetry_detach/1,
    telemetry_execute/3,
    handle/4,
    raise_callback_failure/1,
    span/4,
    convert_native_time/2,
    unique_handler_id/0,
    labelled_handler_id/1,
    unique_correlation/0,
    sha256_hex/1,
    event_parts/1,
    identity/1,
    is_decoding/0,
    decoding/1,
    log_warning/1,
    count_diagnostic/2,
    diagnostics/0
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

%% Every handler is attached as this exported function, with its owner,
%% the token of its registration and the typed Gleam callback as its
%% config. An exported capture keeps telemetry on its fast path and stops
%% it from logging a "local function" warning for each attachment. The
%% native handler table is the record of every registration: the janitor
%% reads owners and tokens back from it (sinal_janitor_ffi).
handle(EventName, Measurements, Metadata, {sinal_owner, _Owner, _Token, Callback}) ->
    Callback(EventName, Measurements, Metadata).

%% A token that names one registration: no other attach gets the same one.
new_token() ->
    make_ref().

telemetry_attach_many(HandlerId, EventNames, Owner, Token, Callback) ->
    ensure_telemetry_started(),
    Config = {sinal_owner, Owner, Token, Callback},
    case telemetry:attach_many(HandlerId, EventNames, fun ?MODULE:handle/4, Config) of
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

%% The span protocol of telemetry:span/3 in the pinned telemetry 1.4.2,
%% with Dispatch in place of telemetry:execute/3, so that each occurrence
%% follows the routes `sinal.emit` follows. The clocks are read and the
%% exception is caught and re-raised here, in the producer. SpanFun returns
%% `{Result, ExtraMeasurements, StopMetadata}`.
span(EventPrefix, StartMetadata, SpanFun, Dispatch) ->
    StartTime = erlang:monotonic_time(),
    Context = erlang:make_ref(),
    Dispatch(
        EventPrefix ++ [start],
        #{monotonic_time => StartTime, system_time => erlang:system_time()},
        merge_context(StartMetadata, Context)
    ),
    try SpanFun() of
        {Result, ExtraMeasurements, StopMetadata} ->
            StopTime = erlang:monotonic_time(),
            Dispatch(
                EventPrefix ++ [stop],
                maps:merge(ExtraMeasurements, #{
                    duration => StopTime - StartTime, monotonic_time => StopTime
                }),
                merge_context(StopMetadata, Context)
            ),
            Result
    catch
        Class:Reason:Stacktrace ->
            StopTime = erlang:monotonic_time(),
            Dispatch(
                EventPrefix ++ [exception],
                #{duration => StopTime - StartTime, monotonic_time => StopTime},
                merge_context(
                    StartMetadata#{kind => Class, reason => Reason, stacktrace => Stacktrace},
                    Context
                )
            ),
            erlang:raise(Class, Reason, Stacktrace)
    end.

merge_context(#{telemetry_span_context := _} = Metadata, _Context) -> Metadata;
merge_context(Metadata, Context) -> Metadata#{telemetry_span_context => Context}.

convert_native_time(Value, Unit) -> erlang:convert_time_unit(Value, native, Unit).

unique_handler_id() ->
    {sinal_handler, erlang:unique_integer([positive])}.

labelled_handler_id(Label) ->
    {sinal_handler, Label, erlang:unique_integer([positive])}.

%% 128 random bits as 32 lowercase hex characters: the shape of a W3C trace
%% id. All zeros is not a valid trace id, so it is redrawn.
unique_correlation() ->
    case crypto:strong_rand_bytes(16) of
        <<0:128>> -> unique_correlation();
        Bytes -> binary:encode_hex(Bytes, lowercase)
    end.

%% The lowercase hexadecimal SHA-256 digest of a binary: 64 characters.
sha256_hex(Value) ->
    binary:encode_hex(crypto:hash(sha256, Value), lowercase).

%% The name and codecs of a `sinal.Event`, for the forwarder, which encodes
%% an event without going through `sinal.emit`'s routes.
event_parts({event, Name, Measurements, Metadata}) ->
    {Name, Measurements, Metadata}.

log_warning(Message) ->
    logger:warning("~ts", [Message], #{domain => [sinal]}),
    nil.

%% Counts one occurrence of a diagnostic condition for an event name and
%% returns the new total. The counter is created on first use and kept in
%% `persistent_term` for the life of the node. Kinds are a closed set and
%% names come from source, so the keys are bounded. Storing a new key does
%% not trigger the global scan that replacing one does; the node-local lock
%% stops two first occurrences from replacing each other's counter.
count_diagnostic(Kind, Name) ->
    Key = {sinal_diagnostic, Kind, Name},
    Counter =
        case persistent_term:get(Key, undefined) of
            undefined ->
                global:trans(
                    {Key, self()},
                    fun() ->
                        case persistent_term:get(Key, undefined) of
                            undefined ->
                                New = atomics:new(1, [{signed, false}]),
                                persistent_term:put(Key, New),
                                New;
                            Existing ->
                                Existing
                        end
                    end,
                    [node()]
                );
            Existing ->
                Existing
        end,
    atomics:add_get(Counter, 1, 1).

%% Every diagnostic counter with its current total, sorted by event name and
%% then kind. Reading scans the node's persistent terms; it is meant for an
%% occasional poll, not a hot path.
diagnostics() ->
    [
        {Kind, Name, Total}
     || {Name, Kind, Total} <- lists:sort([
            {Name, Kind, atomics:get(Counter, 1)}
         || {{sinal_diagnostic, Kind, Name}, Counter} <- persistent_term:get()
        ])
    ].
