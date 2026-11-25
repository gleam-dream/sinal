-module(sinal_janitor_ffi).

-export([capture/1, reraise/1]).

%% Runs Work and returns its value, or the class, reason and stacktrace of
%% the error, exit or throw it raised.
capture(Work) ->
    try Work() of
        Value -> {returned, Value}
    catch
        Class:Reason:Stacktrace -> {raised, {Class, Reason, Stacktrace}}
    end.

reraise({Class, Reason, Stacktrace}) ->
    erlang:raise(Class, Reason, Stacktrace).
