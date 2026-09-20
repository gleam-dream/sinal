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
    telemetry_persist/0,
    sleep/1
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

telemetry_persist() ->
    telemetry:persist().

sleep(Ms) ->
    timer:sleep(Ms).
