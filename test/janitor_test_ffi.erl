-module(janitor_test_ffi).

-export([trace_receives/1, await_down_received/2]).

%% Makes the calling process the tracer of every message Pid receives.
trace_receives(Pid) ->
    1 = erlang:trace(Pid, true, ['receive']),
    nil.

%% Blocks until Pid, traced by the caller, has received the `DOWN` of
%% Owner. A message the caller sends to Pid afterwards is behind that
%% `DOWN` in Pid's mailbox.
await_down_received(Pid, Owner) ->
    receive
        {trace, Pid, 'receive', {'DOWN', _, process, Owner, _}} -> {ok, nil}
    after 5000 ->
        {error, nil}
    end.
