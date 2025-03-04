%% @doc Helper to log long running operations.
-module(long_task).
-export([run_spawn/2, run_tracked/2]).

-ifdef(TEST).
-export([pinfo/2]).
-endif.

-export_type([log_info/0]).

-type log_info() :: map().
%% Extra logging information.

-type task_result() :: term().
%% The generic result of execution.

-type task_fun() :: fun(() -> task_result()).
%% User provided function to execute.

%% @doc Spawns a new process to do some memory-intensive task.
%%
%% This allows to reduce GC on the parent process.
%% Waits for function to finish.
%% Handles errors.
%% Returns result from the function or crashes (i.e. forwards an error).
-spec run_spawn(log_info(), task_fun()) -> task_result().
run_spawn(Info, F) ->
    Pid = self(),
    Ref = make_ref(),
    proc_lib:spawn_link(fun() ->
        try run_tracked(Info, F) of
            Res ->
                Pid ! {result, Ref, Res}
        catch
            Class:Reason:Stacktrace ->
                Pid ! {forward_error, Ref, {Class, Reason, Stacktrace}}
        end
    end),
    receive
        {result, Ref, Res} ->
            Res;
        {forward_error, Ref, {Class, Reason, Stacktrace}} ->
            erlang:raise(Class, Reason, Stacktrace)
    end.

%% @doc Runs function `Fun'.
%%
%% Logs errors.
%% Logs if function execution takes too long.
%% Does not catches the errors - the caller would have to catch
%% if they want to prevent an error.
-spec run_tracked(log_info(), task_fun()) -> task_result().
run_tracked(Info, Fun) ->
    Parent = self(),
    Start = erlang:system_time(millisecond),
    Pid = spawn_mon(Info, Parent, Start),
    try
        Fun()
    catch
        %% Skip nested task_failed errors
        Class:{task_failed, Reason, Info2}:Stacktrace ->
            erlang:raise(Class, {task_failed, Reason, Info2}, Stacktrace);
        Class:Reason:Stacktrace ->
            Log = Info#{
                what => task_failed,
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace,
                caller_pid => Parent,
                long_ref => make_ref()
            },
            ct:pal("~p", [Log]),
            erlang:raise(Class, {task_failed, Reason, Info}, Stacktrace)
    after
        Pid ! stop
    end.

spawn_mon(Info, Parent, Start) ->
    Ref = make_ref(),
    %% We do not link, because we want to log if the Parent dies
    Pid = spawn(fun() -> run_monitor(Info, Ref, Parent, Start) end),
    %% Ensure there is no race conditions by waiting till the monitor is added
    receive
        {monitor_added, Ref} -> ok
    end,
    Pid.

run_monitor(Info, Ref, Parent, Start) ->
    Mon = erlang:monitor(process, Parent),
    Parent ! {monitor_added, Ref},
    Interval = maps:get(report_interval, Info, 5000),
    monitor_loop(Mon, Info, Parent, Start, Interval).

monitor_loop(Mon, Info, Parent, Start, Interval) ->
    receive
        {'DOWN', _MonRef, process, _Pid, shutdown} ->
            %% Special case, the long task is stopped using exit(Pid, shutdown)
            ok;
        {'DOWN', MonRef, process, _Pid, Reason} when Mon =:= MonRef ->
            ct:pal("~p", [Info#{
                what => task_failed,
                reason => Reason,
                caller_pid => Parent,
                reported_by => monitor_process
            }]),
            ok;
        stop ->
            ok
    after Interval ->
        Diff = diff(Start),
        ct:pal("~p", [Info#{
            what => long_task_progress,
            caller_pid => Parent,
            time_ms => Diff,
            current_stacktrace => pinfo(Parent, current_stacktrace),
            dictionary => pinfo(Parent, dictionary)
        }]),
        monitor_loop(Mon, Info, Parent, Start, Interval)
    end.

diff(Start) ->
    erlang:system_time(millisecond) - Start.

pinfo(Pid, Key) ->
    case erlang:process_info(Pid, Key) of
        {Key, Val} ->
            Val;
        undefined ->
            undefined
    end.
