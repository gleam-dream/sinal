-module(owner_test_ffi).

-export([
    janitor/0,
    janitor_pid/0,
    trace_receives/1,
    await_down_received/2,
    sync/1,
    suspend_supervisor/0,
    resume_supervisor/1,
    kill_and_await/1,
    attach_native/3,
    forward/4,
    native_attached/1,
    detach_native/1,
    suspend/1,
    await_attach_received/2,
    resume/1
]).

%% The pid of sinal's janitor, registered under the name `sinal_janitor`.
janitor() ->
    case whereis(sinal_janitor) of
        undefined -> {error, nil};
        Pid -> {ok, Pid}
    end.

janitor_pid() ->
    whereis(sinal_janitor).

%% Makes the calling process the tracer of every message Pid receives.
trace_receives(Pid) ->
    1 = erlang:trace(Pid, true, ['receive']),
    nil.

%% Blocks until Pid, traced by the caller, has received the `DOWN` of
%% Owner, then stops tracing it. A message the caller sends to Pid
%% afterwards is behind that `DOWN` in Pid's mailbox.
await_down_received(Pid, Owner) ->
    Result =
        receive
            {trace, Pid, 'receive', {'DOWN', _, process, Owner, _}} -> {ok, nil}
        after 5000 ->
            {error, nil}
        end,
    try erlang:trace(Pid, false, ['receive']) of
        _ -> ok
    catch
        error:badarg -> ok
    end,
    Result.

%% A round trip through Pid's mailbox: returns once Pid has handled every
%% message that reached it before this call.
sync(Pid) ->
    _ = sys:get_state(Pid),
    nil.

%% Suspends the supervisor of sinal's application, so that a child that
%% exits is not restarted until `resume_supervisor`.
suspend_supervisor() ->
    {ok, Supervisor} = application:get_supervisor(sinal),
    ok = sys:suspend(Supervisor),
    Supervisor.

%% Resumes the supervisor and returns once it has handled the exits that
%% reached it while suspended: `which_children` is answered after them.
resume_supervisor(Supervisor) ->
    ok = sys:resume(Supervisor),
    _ = supervisor:which_children(Supervisor),
    nil.

kill_and_await(Pid) ->
    Monitor = erlang:monitor(process, Pid),
    exit(Pid, kill),
    receive
        {'DOWN', Monitor, process, Pid, _} -> nil
    end.

%% Attaches a native handler the way another library would: a plain
%% `telemetry:attach/4` with its own config, which sends each event to
%% Target.
attach_native(Id, EventName, Target) ->
    ok = telemetry:attach(Id, EventName, fun ?MODULE:forward/4, Target),
    nil.

forward(_EventName, Measurements, _Metadata, Target) ->
    Target ! {native_event, Measurements},
    ok.

native_attached(Id) ->
    lists:any(fun(#{id := HandlerId}) -> HandlerId =:= Id end,
              telemetry:list_handlers([])).

detach_native(Id) ->
    _ = telemetry:detach(Id),
    nil.

%% Suspends Pid, an OTP process: it handles no message until `resume`.
suspend(Pid) ->
    ok = sys:suspend(Pid),
    nil.

resume(Pid) ->
    ok = sys:resume(Pid),
    nil.

%% Blocks until Pid, traced by the caller, has received an attach request
%% for Owner (sent to the janitor's name, so tagged with it), then stops
%% tracing it. Trace messages of earlier requests are skipped.
await_attach_received(Pid, Owner) ->
    Result =
        receive
            {trace, Pid, 'receive', {sinal_janitor, {attach, Owner, _, _, _, _}}} -> {ok, nil}
        after 5000 ->
            {error, nil}
        end,
    try erlang:trace(Pid, false, ['receive']) of
        _ -> ok
    catch
        error:badarg -> ok
    end,
    Result.
