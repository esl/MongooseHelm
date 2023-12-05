-module(mim_kind_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/logger.hrl").

-compile([export_all, nowarn_export_all]).

all() ->
    [{group, all}].

groups() ->
    [{all, [parallel], cases()}].

cases() ->
   [start_3_nodes_cluster,
    upgrade_3_nodes_cluster].

tag() ->
    %% "PR-4182".
    %% "latest".
    "PR-4185".

helm_args(N) ->
    #{"image.tag" => tag(),
      "replicaCount" => integer_to_list(N),
      "persistentDatabase" => "rdbms",
      "rdbms.username" => "mongooseim",
      "rdbms.database" => "mongooseim",
      "volatileDatabase" => "cets",
      "image.pullPolicy" => "Always"}.

start_3_nodes_cluster(_Config) ->
    install_pgsql(),
    N = 3,
    run("helm uninstall mim-test"),
    {0, _} = run("kubectl wait --for=delete pod mongooseim-0 --timeout=60s"),
    run("helm install mim-test MongooseIM " ++ format_args(helm_args(N))),
    run("kubectl wait --for=condition=ready pod mongooseim-0"),
    run("kubectl exec -it mongooseim-0 -- mongooseimctl cets systemInfo"),
    LastNode = "mongooseim-" ++ integer_to_list(N - 1),
    run("kubectl wait statefulset mongooseim --for jsonpath=status.availableReplicas=3"),
    run("kubectl wait --for=condition=ready pod " ++ LastNode),
    wait_for_joined_nodes_count("mongooseim-0", N),
    ?assertEqual(0, unavailable_nodes_count("mongooseim-0")),
    ok.

upgrade_3_nodes_cluster(_Config) ->
    N = 3,
    run("helm upgrade mim-test MongooseIM " ++ format_args(helm_args(N))),
    wait_for_upgrade().

wait_for_upgrade() ->
    Validator = fun({_, Text}) ->
        Match = binary:match(Text, <<"statefulset rolling update complete 3 pods at revision">>),
        Match =/= nomatch end,
    %% Just "kubectl rollout status statefulset.apps/mongooseim" (blocking version)
    %% would break with "error: object has been deleted" after 20 seconds.
    %% Use active monitoring here.
    Cmd = "kubectl rollout status statefulset.apps/mongooseim --watch=false",
    WaitOpts = #{sleep_time => timer:seconds(1), validator => Validator, time_left => timer:seconds(180)},
    test_wait:wait_until(fun() -> run(Cmd) end, true, WaitOpts),
    ok.


run(Cmd) ->
    run(Cmd, #{}).

run(Cmd, Opts) ->
    {Diff, {Code, Res}} = timer:tc(fun() -> cmd(Cmd, Opts) end),
    ct:log("CMD ~ts~n~pms~nResult ~p ~ts", [Cmd, Diff, Code, Res]),
    {Code, Res}.

install_pgsql() ->
    %% See https://github.com/bitnami/charts/tree/main/bitnami/postgresql
    run("helm uninstall ct-pg"),
    %% Remove old volume
    run("kubectl delete pvc data-ct-pg-postgresql-0"),
    run("helm install ct-pg oci://registry-1.docker.io/bitnamicharts/postgresql"),
    run("curl https://raw.githubusercontent.com/esl/MongooseIM/master/priv/pg.sql -o _build/pg.sql"),
    run("kubectl wait --for=condition=ready pod ct-pg-postgresql-0"),
    run("kubectl cp test/init.sql ct-pg-postgresql-0:/tmp/init.sql"),
    run("kubectl cp _build/pg.sql ct-pg-postgresql-0:/tmp/pg.sql"),
    run("kubectl exec ct-pg-postgresql-0 -- sh -c 'PGPASSWORD=$POSTGRES_PASSWORD psql -U postgres -f /tmp/init.sql'"),
    run("kubectl exec ct-pg-postgresql-0 -- sh -c 'PGPASSWORD=$POSTGRES_PASSWORD psql -U postgres -d mongooseim -f /tmp/pg.sql'"),
    ok.

cmd(Cmd) ->
   cmd(Cmd, #{}).

cmd(Cmd, Opts) ->
    {ok, CWD} = file:get_cwd(),
    PortOpts =
        [{cd, filename:join(CWD, "../../../../")}, exit_status, use_stdio, binary]
        ++ [stderr_to_stdout || maps:get(stderr_to_stdout, Opts, true)],
    Port = erlang:open_port({spawn, Cmd}, PortOpts),
    receive_loop(Cmd, Port, <<>>).

run_json(Cmd) ->
    {0, Text} = run(Cmd, #{stderr_to_stdout => false}),
    JSON = jiffy:decode(Text, [return_maps]),
    ct:pal("~p", [JSON]),
    JSON.

receive_loop(Cmd, Port, Res) ->
    receive
        {Port, {data, Data}} ->
            receive_loop(Cmd, Port, <<Res/binary, Data/binary>>);
        {Port, {exit_status, Code}} ->
            {Code, Res}
        after 60000 ->
            error({cmd_timeout, Cmd})
    end.

system_info(Node) ->
    JSON = run_json("kubectl exec -it " ++ Node ++ " -- mongooseimctl cets systemInfo"),
    #{<<"data">> := #{<<"cets">> := #{<<"systemInfo">> := Info}}} = JSON,
    Info.

joined_nodes_count(Node) ->
    #{<<"joinedNodes">> := Joined} = system_info(Node),
    length(Joined).

unavailable_nodes_count(Node) ->
    #{<<"unavailableNodes">> := Unavailable} = system_info(Node),
    length(Unavailable).

wait_for_joined_nodes_count(Node, ExpectedCount) ->
    test_wait:wait_until(fun() -> joined_nodes_count(Node) end, ExpectedCount).

format_args(Map) ->
    lists:append([format_arg(Key, Value) || {Key, Value} <- maps:to_list(Map)]).

format_arg(Key, Value) ->
    " --set " ++ Key ++ "=" ++ Value.
