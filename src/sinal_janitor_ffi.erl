-module(sinal_janitor_ffi).

-export([capture/1, reraise/1, name/0, owned_handlers/0, await_restart/0]).

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

%% Every sinal handler in the native handler table, as `{Owner, Id}`. The
%% owner is read from the handler's config, which sinal_ffi:handle/4
%% receives as `{sinal_owner, Owner, Callback}`. Handlers attached by other
%% libraries have another function or config and are left out. A handler
%% attached to several events is listed once.
owned_handlers() ->
    case whereis(telemetry_handler_table) of
        undefined ->
            [];
        _ ->
            Handle = fun sinal_ffi:handle/4,
            lists:usort([
                {Owner, Id}
             || #{id := Id, function := Function, config := {sinal_owner, Owner, _}}
                    <- telemetry:list_handlers([]),
                Function =:= Handle
            ])
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
