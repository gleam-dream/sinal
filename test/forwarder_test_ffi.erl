-module(forwarder_test_ffi).

-export([message_queue_len/1]).

%% Reads a process's current mailbox length. Test-only introspection: used to
%% observe how many messages a guard actually queued, rather than only the
%% final effect of processing them. Returns -1 for a dead process instead of
%% `undefined`, so callers get an integer either way.
message_queue_len(Pid) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, N} -> N;
        undefined -> -1
    end.
