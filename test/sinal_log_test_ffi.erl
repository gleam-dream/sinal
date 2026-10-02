-module(sinal_log_test_ffi).

-export([capture_warnings/1, log/2]).

%% Adds a logger handler that forwards each warning logged by the calling
%% process to it, runs Work, and returns Work's result with the formatted
%% messages. Logger calls a handler in the logging process, so the handler
%% filters on that process.
capture_warnings(Work) ->
    Id = list_to_atom("sinal_log_capture_" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = logger:add_handler(Id, ?MODULE, #{level => warning, config => #{owner => self()}}),
    Result =
        try
            Work()
        after
            logger:remove_handler(Id)
        end,
    {Result, collect([])}.

collect(Acc) ->
    receive
        {sinal_log_capture, Message} -> collect([Message | Acc])
    after 0 ->
        lists:reverse(Acc)
    end.

log(#{msg := Msg, meta := Meta}, #{config := #{owner := Owner}}) ->
    case maps:get(pid, Meta, undefined) of
        Owner -> Owner ! {sinal_log_capture, unicode:characters_to_binary(format(Msg))};
        _ -> ok
    end.

format({string, Chardata}) -> Chardata;
format({report, Report}) -> io_lib:format("~p", [Report]);
format({Format, Args}) -> io_lib:format(Format, Args).
