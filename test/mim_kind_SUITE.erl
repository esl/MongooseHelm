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
   [start_3_nodes_cluster].

tag() ->
    "PR-4182".
    %% "latest".

start_3_nodes_cluster(Config) ->
    install_pgsql(),
    N = 3,
    run("helm uninstall mim-test"),
    {0, _} = run("kubectl wait --for=delete pod mongooseim-0 --timeout=60s"),
    run("helm install mim-test MongooseIM --set image.tag=" ++ tag() ++ " --set replicaCount=" ++ integer_to_list(N) ++ " --set persistentDatabase=rdbms --set rdbms.username=mongooseim --set rdbms.database=mongooseim --set volatileDatabase=cets --set image.pullPolicy=Always"),
    run("kubectl wait --for=condition=ready pod mongooseim-0"),
    run("kubectl exec -it mongooseim-0 -- mongooseimctl cets systemInfo"),
    LastNode = "mongooseim-" ++ integer_to_list(N - 1),
    run("kubectl wait statefulset mongooseim --for jsonpath=status.availableReplicas=3"),
    run("kubectl wait --for=condition=ready pod " ++ LastNode),
    wait_for_joined_nodes_count("mongooseim-0", 3),
    ok.

run(Cmd) ->
    run(Cmd, #{}).

run(Cmd, Opts) ->
    ct:log("CMD ~ts", [Cmd]),
    {Code, Res} = cmd(Cmd, Opts),
    ct:log("Result ~p ~ts", [Code, Res]),
    {Code, Res}.

install_pgsql() ->
    %% See https://github.com/bitnami/charts/tree/main/bitnami/postgresql
    run("helm uninstall ct-pg"),
    %% Remove old volume
    run("kubectl delete pvc data-ct-pg-postgresql-0"),
    run("helm install ct-pg oci://registry-1.docker.io/bitnamicharts/postgresql"),
    run("kubectl wait --for=condition=ready pod ct-pg-postgresql-0"),
    run("curl https://raw.githubusercontent.com/esl/MongooseIM/master/priv/pg.sql -o _build/pg.sql"),
    run("kubectl cp test/init.sql ct-pg-postgresql-0:/tmp/init.sql"),
    run("kubectl cp _build/pg.sql ct-pg-postgresql-0:/tmp/pg.sql"),
    run("kubectl exec ct-pg-postgresql-0 -- sh -c 'PGPASSWORD=$POSTGRES_PASSWORD psql -U postgres -f /tmp/init.sql'"),
    run("kubectl exec ct-pg-postgresql-0 -- sh -c 'PGPASSWORD=$POSTGRES_PASSWORD psql -U postgres -d mongooseim -f /tmp/pg.sql'"),
    ok.

cmd(Cmd) ->
   cmd(Cmd, #{}).

cmd(Cmd, Opts) ->
    {ok, CWD} = file:get_cwd(),
    PortOpts = [stderr_to_stdout || maps:get(stderr_to_stdout, Opts, true)],
    Port = erlang:open_port({spawn, Cmd}, [{cd, filename:join(CWD, "../../../../")}, exit_status, use_stdio, binary] ++ PortOpts),
    receive_loop(Cmd, Port, <<>>).

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
    {0, Text} = run("kubectl exec -it " ++ Node ++ " -- mongooseimctl cets systemInfo", #{stderr_to_stdout => false}),
    JSON = jiffy:decode(Text, [return_maps]),
    ct:pal("~p", [JSON]),
    #{<<"data">> := #{<<"cets">> := #{<<"systemInfo">> := Info}}} = JSON,
    Info.

joined_nodes_count(Node) ->
    #{<<"joinedNodes">> := Joined} = system_info(Node),
    length(Joined).

wait_for_joined_nodes_count(Node, ExpectedCount) ->
    test_wait:wait_until(fun() -> joined_nodes_count(Node) end, ExpectedCount).
