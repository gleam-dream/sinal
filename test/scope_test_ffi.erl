-module(scope_test_ffi).

-export([
    catch_exception/1,
    raise_test_error/1,
    raise_test_exit/1,
    raise_test_throw/1,
    is_stacktrace_list/1,
    decode_failure_event/2,
    is_callback_failure_reason/2,
    is_panic_reason/2,
    term_equals/2,
    native_map/1,
    native_emit/3,
    panic_message/1,
    span_context_term/1,
    handler_records/1,
    native_to_milliseconds/1,
    native_to_nanoseconds/1,
    telemetry_persist/0,
    sleep/1,
    is_native_integer/1,
    is_positive_integer/1,
    is_non_negative_integer/1,
    is_native_reference/1,
    has_origin_frame/3,
    get_otp_release/0,
    monotonic_nanos/0,
    read_file/1
]).

catch_exception(Fun) ->
    try Fun() of
        Val -> {returned, Val}
    catch
        Class:Reason:Stacktrace ->
            {caught_exception, atom_to_binary(Class, utf8), Reason, Stacktrace}
    end.

raise_test_error(Reason) ->
    erlang:error(Reason).

raise_test_exit(Reason) ->
    erlang:exit(Reason).

raise_test_throw(Reason) ->
    erlang:throw(Reason).

is_stacktrace_list(Stacktrace) ->
    is_list(Stacktrace) andalso length(Stacktrace) > 0.

decode_failure_event(Measurements, Metadata) ->
    Monotonic = maps:get(monotonic_time, Measurements, 0),
    System = maps:get(system_time, Measurements, 0),
    RawEventName = maps:get(event_name, Metadata, []),
    EventName = [atom_to_binary(A, utf8) || A <- RawEventName],
    HandlerId = maps:get(handler_id, Metadata, nil),
    HandlerConfig = maps:get(handler_config, Metadata, nil),
    Kind = case maps:get(kind, Metadata, undefined) of
        K when is_atom(K) -> atom_to_binary(K, utf8);
        _ -> <<"unknown">>
    end,
    Reason = maps:get(reason, Metadata, nil),
    Stacktrace = maps:get(stacktrace, Metadata, []),
    HasStacktrace = is_list(Stacktrace) andalso length(Stacktrace) > 0,
    HasValidTimes = is_integer(Monotonic) andalso is_integer(System),
    {telemetry_failure_record,
        HasValidTimes,
        Monotonic,
        System,
        EventName,
        HandlerId,
        HandlerConfig,
        Kind,
        Reason,
        HasStacktrace}.

is_callback_failure_reason({sinal_callback_failure, Bin}, Expected) when is_binary(Bin), is_binary(Expected) ->
    Bin =:= Expected;
is_callback_failure_reason(_, _) ->
    false.

is_panic_reason(#{gleam_error := panic, message := Msg}, Expected) when is_binary(Msg), is_binary(Expected) ->
    Msg =:= Expected;
is_panic_reason({panic, Bin}, Expected) when is_binary(Bin), is_binary(Expected) ->
    Bin =:= Expected;
is_panic_reason(Bin, Expected) when is_binary(Bin), is_binary(Expected) ->
    Bin =:= Expected;
is_panic_reason(_, _) ->
    false.

term_equals(A, B) ->
    A =:= B.

%% A native map with atom keys, as a foreign producer would build it.
native_map(Pairs) ->
    maps:from_list([{binary_to_atom(Key, utf8), Value} || {Key, Value} <- Pairs]).

%% Executes an event directly through telemetry, bypassing sinal's encoding
%% and routes.
native_emit(Name, Measurements, Metadata) ->
    telemetry:execute([binary_to_atom(Segment, utf8) || Segment <- Name], Measurements, Metadata),
    nil.

%% Runs Fun and returns the message of the Gleam panic it raises.
panic_message(Fun) ->
    try Fun() of
        _ -> {error, nil}
    catch
        error:#{gleam_error := panic, message := Message} -> {ok, Message}
    end.

%% The id and function type of each native handler of exactly this event.
handler_records(Name) ->
    EventName = [binary_to_atom(Segment, utf8) || Segment <- Name],
    [{Id, element(2, erlang:fun_info(Function, type))}
     || #{id := Id, event_name := Event, function := Function}
            <- telemetry:list_handlers(EventName),
        Event =:= EventName].

%% The native term inside an opaque `span.SpanContext`.
span_context_term({span_context, Term}) -> Term.

native_to_milliseconds(Value) ->
    erlang:convert_time_unit(Value, native, millisecond).

native_to_nanoseconds(Value) ->
    erlang:convert_time_unit(Value, native, nanosecond).

telemetry_persist() ->
    telemetry:persist().

sleep(Ms) ->
    timer:sleep(Ms).

is_native_integer(Term) ->
    is_integer(Term).

is_positive_integer(Term) ->
    is_integer(Term) andalso Term > 0.

is_non_negative_integer(Term) ->
    is_integer(Term) andalso Term >= 0.

is_native_reference(Term) ->
    is_reference(Term).

has_origin_frame(Stacktrace, ModBin, FunBin) when is_list(Stacktrace), is_binary(ModBin), is_binary(FunBin) ->
    try
        ModAtom = binary_to_existing_atom(ModBin, utf8),
        FunAtom = binary_to_existing_atom(FunBin, utf8),
        has_origin_frame_loop(Stacktrace, ModAtom, FunAtom)
    catch
        error:badarg -> false
    end;
has_origin_frame(_, _, _) ->
    false.

has_origin_frame_loop([{Mod, Fun, _Arity, _Location} | _], Mod, Fun) ->
    true;
has_origin_frame_loop([{Mod, Fun, _Args} | _], Mod, Fun) ->
    true;
has_origin_frame_loop([_ | Rest], Mod, Fun) ->
    has_origin_frame_loop(Rest, Mod, Fun);
has_origin_frame_loop([], _, _) ->
    false.

get_otp_release() ->
    list_to_binary(erlang:system_info(otp_release)).

monotonic_nanos() ->
    erlang:monotonic_time(nanosecond).

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> {ok, Bin};
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end.
