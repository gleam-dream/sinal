-module(collector_test_ffi).

-export([trace_receives/1, await_restart/2]).

%% Makes the calling process the tracer of every message Pid receives.
trace_receives(Pid) ->
    1 = erlang:trace(Pid, true, ['receive']),
    nil.

%% Blocks until Supervisor, traced by the caller, has received the exit of
%% Child and has handled it. The supervisor restarts the child while it
%% handles that exit, and the call made here queues behind the exit.
await_restart(Supervisor, Child) ->
    receive
        {trace, Supervisor, 'receive', {'EXIT', Child, _}} ->
            _ = supervisor:which_children(Supervisor),
            {ok, nil}
    after 5000 ->
        {error, nil}
    end.
