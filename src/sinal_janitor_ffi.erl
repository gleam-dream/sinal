-module(sinal_janitor_ffi).

-export([
    capture/1,
    reraise/1,
    name/0,
    send/2,
    owners/0,
    handlers_of/1,
    holder/1,
    detach_registration/2,
    await_restart/0
]).

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

%% The janitor's registered name. One fixed atom, written in source.
name() ->
    sinal_janitor.

%% Sends Message to janitor process Pid as a message to its name, so the
%% request reaches that incarnation and no later one.
send(Pid, Message) ->
    Pid ! {name(), Message},
    nil.

%% Every sinal handler in the native handler table, as `{Owner, Id, Token}`,
%% read from the config sinal_ffi:handle/4 receives as
%% `{sinal_owner, Owner, Token, Callback}`. Handlers attached by other
%% libraries have another function or config and are left out. A handler
%% attached to several events is listed once.
%%
%% Telemetry inserts and deletes through its handler table server and
%% reads the table directly. A synchronous call to that server first lets
%% it apply the requests queued before this read, such as an insert from a
%% janitor that exited while waiting for it.
registrations() ->
    case whereis(telemetry_handler_table) of
        undefined ->
            [];
        Server ->
            try sys:get_state(Server) of
                _ -> ok
            catch
                exit:_ -> ok
            end,
            Handle = fun sinal_ffi:handle/4,
            lists:usort([
                {Owner, Id, Token}
             || #{id := Id, function := Function, config := {sinal_owner, Owner, Token, _}}
                    <- telemetry:list_handlers([]),
                Function =:= Handle
            ])
    end.

%% The owners of every sinal handler, each once.
owners() ->
    lists:usort([Owner || {Owner, _, _} <- registrations()]).

%% The `{Id, Token}` of every sinal handler whose config names Owner.
handlers_of(Owner) ->
    [{Id, Token} || {HandlerOwner, Id, Token} <- registrations(), HandlerOwner =:= Owner].

%% The owner and token of the sinal handler attached under Id, if any.
holder(Id) ->
    case [{Owner, Token} || {Owner, HandlerId, Token} <- registrations(), HandlerId =:= Id] of
        [Holder | _] -> {ok, Holder};
        [] -> {error, nil}
    end.

%% Detaches the registration Token under Id. Does nothing, and returns an
%% error, when Id holds another registration or none: telemetry detaches
%% by id alone, so the token is checked first.
detach_registration(Id, Token) ->
    case holder(Id) of
        {ok, {_, Token}} -> sinal_ffi:telemetry_detach(Id);
        _ -> {error, nil}
    end.

%% Called while the janitor is not registered. Starts the sinal application
%% when it is not running (which starts the janitor), then makes one call to
%% the application's supervisor: the supervisor answers it only between
%% restarts, so a janitor being restarted has registered by then unless its
%% exit had not reached the supervisor yet.
await_restart() ->
    case application:ensure_all_started(sinal) of
        {ok, _} -> ok;
        {error, Reason} -> erlang:error({sinal_not_started, Reason})
    end,
    case application:get_supervisor(sinal) of
        {ok, Supervisor} ->
            try supervisor:which_children(Supervisor) of
                _ -> nil
            catch
                exit:_ -> nil
            end;
        undefined ->
            nil
    end.
