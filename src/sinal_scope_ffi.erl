-module(sinal_scope_ffi).

-export([
    with_subscription_scope/3,
    cleanup_subscriptions/1,
    acquire_subscription/1,
    cleanup_and_reraise/3
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

%% Runs every cleanup, newest first, and returns the failures in that
%% order as `SubscriptionCleanupFailure(index, CleanupFailure)` values.
cleanup_subscriptions(Cleanups) ->
    lists:reverse(lists:foldl(fun({Index, Cleanup}, Failures) ->
        case capture_work(Cleanup) of
            {returned, {ok, nil}} -> Failures;
            {returned, {error, nil}} ->
                [{subscription_cleanup_failure, Index, already_detached} | Failures];
            {raised, {Class, Reason, _Stacktrace}} ->
                [{subscription_cleanup_failure, Index,
                  {detach_crashed, describe(Class, Reason)}} | Failures]
        end
    end, [], Cleanups)).

describe(Class, Reason) ->
    unicode:characters_to_binary(io_lib:format("~p: ~0p", [Class, Reason])).

capture_work(Work) ->
    try Work() of
        WorkResult -> {returned, WorkResult}
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
