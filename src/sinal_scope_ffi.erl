-module(sinal_scope_ffi).

-export([
    with_scope/3,
    with_subscription_scope/3,
    cleanup_subscriptions/1,
    acquire_subscription/1,
    cleanup_and_reraise/3,
    reraise/1,
    exception_class/1
]).

acquire_subscription(Acquire) ->
    case capture_work(Acquire) of
        {returned, Result} -> {acquired, Result};
        {raised, Exception} -> {acquisition_raised, Exception}
    end.

cleanup_and_reraise(Cleanups, OnCleanupFailure, Exception) ->
    Failures = cleanup_subscriptions(Cleanups),
    lists:foreach(fun(Failure) -> safely_notify(OnCleanupFailure, Failure) end, Failures),
    reraise(Exception).

with_subscription_scope(Work, Cleanups, OnCleanupFailure) ->
    case capture_work(Work) of
        {returned, WorkResult} ->
            {subscription_completion, WorkResult, cleanup_subscriptions(Cleanups)};
        {raised, WorkException} ->
            Failures = cleanup_subscriptions(Cleanups),
            lists:foreach(fun(Failure) -> safely_notify(OnCleanupFailure, Failure) end, Failures),
            reraise(WorkException)
    end.

cleanup_subscriptions(Cleanups) ->
    lists:reverse(lists:foldl(fun({Index, Cleanup}, Failures) ->
        case attempt_cleanup(Cleanup) of
            {returned, {ok, nil}} -> Failures;
            {returned, {error, DetachError}} ->
                [{subscription_cleanup_failure, Index,
                  {detach_returned_error, DetachError}} | Failures];
            {raised, Exception} ->
                [{subscription_cleanup_failure, Index,
                  {detach_raised_exception, Exception}} | Failures]
        end
    end, [], Cleanups)).

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
