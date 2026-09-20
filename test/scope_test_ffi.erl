-module(scope_test_ffi).
-export([catch_exception/1, raise_test_error/1]).

catch_exception(Fun) ->
    try Fun() of
        Val -> {ok, Val}
    catch
        Class:Reason:Stacktrace ->
            {caught, Class, Reason, {Class, Reason, Stacktrace}}
    end.

raise_test_error(Reason) ->
    erlang:error(Reason).
