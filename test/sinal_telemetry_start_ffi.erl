-module(sinal_telemetry_start_ffi).
-export([run_in_fresh_vm/0, telemetry_running/0, stop_telemetry/0]).

%% Runs `sinal_telemetry_start_probe:run/0` in a peer VM that has this
%% build's code but has started no application beyond kernel and stdlib,
%% so telemetry is loaded but not running.
run_in_fresh_vm() ->
    Root = code:root_dir(),
    Paths = [Path || Path <- code:get_path(), not lists:prefix(Root, Path)],
    Args = ["-kernel", "logger_level", "warning" | lists:append([["-pa", Path] || Path <- Paths])],
    {ok, Peer, _Node} = peer:start_link(#{connection => standard_io, args => Args}),
    try
        peer:call(Peer, sinal_telemetry_start_probe, run, [], 20000)
    after
        peer:stop(Peer)
    end.

telemetry_running() ->
    lists:keymember(telemetry, 1, application:which_applications()).

stop_telemetry() ->
    ok = application:stop(telemetry),
    nil.
