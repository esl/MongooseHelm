-module(log_checker).
-export([check_logs/1]).

-include_lib("eunit/include/eunit.hrl").

check_logs(LogBinary) ->
    LogLines = string:split(binary_to_list(LogBinary), "\n", all),
    FilteredLines = lists:filter(fun(Line) -> filter_line(Line) end, LogLines),
    ParsedLogs = lists:map(fun extract_logs/1, FilteredLines),
    ?assertEqual(3, length(ParsedLogs), ParsedLogs),
    lists:foreach(fun(Log) -> check_log(Log) end, ParsedLogs).

filter_line(Line) ->
    starts_with(Line, "when=") andalso
        not lists:any(fun(Txt) -> contains(Line, Txt) end, ignore_strings()).

%% Return true if Txt is in Line
contains(Line, Txt) ->
    string:str(Line, Txt) > 0.

ignore_strings() ->
    ["system_memory_high_watermark"].

starts_with(Line, Prefix) ->
    case string:prefix(Line, Prefix) of
        nomatch -> false;
        _ -> true
    end.

extract_logs(Line) ->
    When = extract_log_field(Line, "when=([^ ]+)"),
    Level = extract_log_field(Line, "level=([^ ]+)"),
    What = extract_log_field(Line, "what=([^ ]+)"),
    Pid = extract_log_field(Line, "pid=([^ ]+)"),
    At = extract_log_field(Line, "\sat=([^ ]+)"),
    #{'when' => When, level => Level, what => What, pid => Pid, at => At}.

extract_log_field(Line, Pattern) ->
    case re:run(Line, Pattern, [{capture, all_but_first, list}]) of
        {match, [Matched]} ->
            Matched;
        _ ->
            not_found
    end.

check_log(Log) ->
    Predicates = [
        fun check_what/1,
        fun check_level/1
    ],
    IsValidLog = lists:all(fun(Predicate) -> Predicate(Log) end, Predicates),
    ?assertEqual(true, IsValidLog,
                 lists:flatten(io_lib:format("Unexpected log encountered: ~p", [Log]))).

check_what(Log) ->
    AllowedWhats = ["nodeup", "report_transparency"],
    What = maps:get(what, Log, undefined),
    lists:member(What, AllowedWhats).

check_level(Log) ->
    Level = maps:get(level, Log, undefined),
    Level /= "error".
