-module(collector_test_ffi).

-export([trace_receives/1, await_restart/2, handler_count/1, terminate_child/1]).

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

%% How many handlers are attached to exactly this event name.
handler_count(Name) ->
    EventName = [binary_to_atom(Segment) || Segment <- Name],
    length([H || #{event_name := E} = H <- telemetry:list_handlers(EventName), E =:= EventName]).

%% Stops the supervisor's only child, the collector.
terminate_child(Supervisor) ->
    [{Id, _, _, _}] = supervisor:which_children(Supervisor),
    ok = supervisor:terminate_child(Supervisor, Id),
    nil.
