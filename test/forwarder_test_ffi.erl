-module(forwarder_test_ffi).

-export([message_queue_len/1, identity/1, forwarder_counters/1]).

%% Reads a process's current mailbox length. Test-only introspection: used to
%% observe how many messages a guard actually queued, rather than only the
%% final effect of processing them. Returns -1 for a dead process instead of
%% `undefined`, so callers get an integer either way.
message_queue_len(Pid) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, N} -> N;
        undefined -> -1
    end.

identity(X) -> X.

%% Reads the counters out of an opaque `Forwarder`, whose runtime value is the
%% record tuple `{forwarder, Name, Capacity, Counters}`. Test-only: it lets a
%% test place a drop in a race window no public call can reach on demand.
forwarder_counters({forwarder, _Name, _Capacity, Counters}) -> Counters.
