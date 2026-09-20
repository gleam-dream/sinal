-module(sinal_scope_ffi).

-export([
    with_scope/3,
    reraise/1,
    exception_class/1
]).

with_scope(Work, Cleanup, OnCleanupFailure) ->
    case capture_work(Work) of
        {returned, WorkResult} ->
            {scoped_completion, WorkResult, cleanup_result(Cleanup)};
        {raised, WorkException} ->
            cleanup_after_exception(Cleanup, OnCleanupFailure),
            reraise(WorkException)
    end.

capture_work(Work) ->
    try Work() of
        WorkResult -> {returned, WorkResult}
    catch
        Class:Reason:Stacktrace -> {raised, {Class, Reason, Stacktrace}}
    end.

cleanup_result(Cleanup) ->
    case attempt_cleanup(Cleanup) of
        {returned, {ok, nil}} -> {ok, nil};
        {returned, {error, DetachError}} ->
            {error, {detach_returned_error, DetachError}};
        {raised, Exception} -> {error, {detach_raised_exception, Exception}}
    end.

cleanup_after_exception(Cleanup, OnCleanupFailure) ->
    case attempt_cleanup(Cleanup) of
        {returned, {ok, nil}} -> ok;
        {returned, {error, DetachError}} ->
            safely_notify(OnCleanupFailure, {detach_returned_error, DetachError});
        {raised, Exception} ->
            safely_notify(OnCleanupFailure, {detach_raised_exception, Exception})
    end.

attempt_cleanup(Cleanup) ->
    try Cleanup() of
        Result -> {returned, Result}
    catch
        Class:Reason:Stacktrace -> {raised, {Class, Reason, Stacktrace}}
    end.

safely_notify(Callback, Failure) ->
    try Callback(Failure) of
        _ -> ok
    catch
        _Class:_Reason:_Stacktrace -> ok
    end.

reraise({Class, Reason, Stacktrace}) -> erlang:raise(Class, Reason, Stacktrace).

exception_class({error, _Reason, _Stacktrace}) -> error_class;
exception_class({exit, _Reason, _Stacktrace}) -> exit_class;
exception_class({throw, _Reason, _Stacktrace}) -> throw_class.
