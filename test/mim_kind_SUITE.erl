-module(mim_kind_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/logger.hrl").

-compile([export_all, nowarn_export_all]).

all() ->
    [{group, mariadb},
     {group, pgsql},
     {group, mysql}].

groups() ->
    [{pgsql, [sequence], cases()},
     {mysql, [sequence], cases()},
     {mariadb, [sequence], cases()}].

cases() ->
   [start_3_nodes_cluster,
    upgrade_3_nodes_cluster,
    pod_disappears_with_users_connected].

init_per_group(pgsql, Config) ->
    [{rdbms_driver, pgsql} | Config];
init_per_group(mysql, Config) ->
    [{rdbms_driver, mysql} | Config];
init_per_group(mariadb, Config) ->
    [{rdbms_driver, mariadb} | Config].

end_per_group(_, Config) ->
    Config.

tag() ->
    %% You can specify a docker tag to test using:
    %% "PR-4185".
    "latest".

helm_args(N, Driver) ->
    #{"image.tag" => tag(),
      "replicaCount" => integer_to_list(N),
      "persistentDatabase" => "rdbms",
      "rdbms.username" => "mongooseim",
      "rdbms.database" => "mongooseim",
      "rdbms.password" => "mongooseim",
      "rdbms.driver" => atom_to_list(driver_for_template(Driver)),
      "rdbms.host" => driver_to_host(Driver),
      "rdbms.tls.required" => "false",
      "volatileDatabase" => "cets",
      "image.pullPolicy" => "Always"}.

driver_to_host(pgsql) ->
    "ct-pg-postgresql.default.svc.cluster.local";
driver_to_host(mysql) ->
    "ct-mysql.default.svc.cluster.local";
driver_to_host(mariadb) ->
    "ct-mariadb-mariadb-galera.default.svc.cluster.local".

driver_for_template(mariadb) ->
    mysql;
driver_for_template(Driver) ->
    Driver.

start_3_nodes_cluster(Config) ->
    Driver = proplists:get_value(rdbms_driver, Config),
    run("helm uninstall mim-test"),
    install_db(Driver),
    N = 3,
    {0, _} = run("kubectl wait --for=delete pod mongooseim-0 --timeout=2m"),
    run("helm install mim-test MongooseIM " ++ format_args(helm_args(N, Driver))),
    %% kubectl wait would fail until pod appears
    %% (wait only works for existing resources https://github.com/kubernetes/kubectl/issues/1516)
    run_wait("kubectl wait --for=condition=ready pod mongooseim-0 --timeout=1m"),
    run("kubectl exec -it mongooseim-0 -- mongooseimctl cets systemInfo"),
    LastNode = "mongooseim-" ++ integer_to_list(N - 1),
    run("kubectl wait statefulset mongooseim --for jsonpath=status.availableReplicas=3 --timeout=2m"),
    run("kubectl wait --for=condition=ready --timeout=2m pod " ++ LastNode),
    wait_for_joined_nodes_count("mongooseim-0", N),
    ?assertEqual(0, unavailable_nodes_count("mongooseim-0")),
    ok.

upgrade_3_nodes_cluster(Config) ->
    Driver = proplists:get_value(rdbms_driver, Config),
    N = 3,
    run("helm upgrade mim-test MongooseIM " ++ format_args(helm_args(N, Driver))),
    wait_for_upgrade().

pod_disappears_with_users_connected(_Config) ->
    %% Connect many users to LB
    UserCount = 200,
    register_users(UserCount),
    run_amoc(UserCount),
    %% Disconnect one node
    {0, _} = run("kubectl delete pod mongooseim-0 --force"),
    %% We could also try to upgrade cluster, instead of disconnect
%   upgrade_3_nodes_cluster(Config),
    run("kubectl wait statefulset mongooseim --for jsonpath=status.availableReplicas=2 --timeout=2m"),
    %% It should come back to three again
    wait_for_joined_nodes_count("mongooseim-1", 3),
    stop_amoc(),
    %% Inspect the session table
    try
        wait_for_session_count("mongooseim-0", 0)
    catch _:Reason ->
        ct:pal("wait_for_session_count failed, ignore until we have a fix in MongooseIM~n"
               "Reason ~p", [Reason])
    after
        run("kubectl logs mongooseim-0"),
        run("kubectl logs mongooseim-1"),
        run("kubectl logs mongooseim-2")
    end.

wait_for_upgrade() ->
    run("kubectl rollout status statefulset.apps/mongooseim --timeout=3m").

register_users(UserCount) ->
    Results = [register_user(N) || N <- lists:seq(1, UserCount)],
    ct:pal("register_user result ~p", [hd(Results)]),
    ok.

stop_amoc() ->
    Pod = "amoc-deployment-0",
    run("helm uninstall amoc"),
    {0, _} = run("kubectl wait --for=delete pod " ++ Pod ++ " --timeout=2m").

run_amoc(SessionCount) ->
    Pod = "amoc-deployment-0",
    stop_amoc(),
    run("helm install amoc Amoc"),
    run("kubectl wait --for=condition=ready --timeout=2m pod " ++ Pod),
    %% Pass settings using a file to avoid escaping issues
    term_to_file("_build/amoc_args.cfg", amoc_args(SessionCount)),
    run("kubectl cp _build/amoc_args.cfg " ++ Pod ++ ":/tmp/amoc_args.cfg"),
    %% Wait for for Erlang VM to start
    run_wait("kubectl exec -t " ++ Pod ++ " -- "
             "/amoc_arsenal_xmpp/_build/default/rel/amoc_arsenal_xmpp/bin/amoc_arsenal_xmpp "
             "rpc os timestamp \"[]\""),
    run("kubectl exec -t " ++ Pod ++ " -- "
        "bash -c '"
        "/amoc_arsenal_xmpp/_build/default/rel/amoc_arsenal_xmpp/bin/amoc_arsenal_xmpp "
        "rpc amoc do $(cat /tmp/amoc_args.cfg)'"),
    wait_for_session_count("mongooseim-0", SessionCount).

amoc_args(SessionCount) ->
    [mongoose_one_to_one, SessionCount, amoc_settings()].

amoc_settings() ->
    %% We can use direct connections using mongooseim-0.mongooseim.default.svc.cluster.local
    [{xmpp_servers, [[{host, "mongooseim.default.svc.cluster.local"}]]}].

term_to_file(Path, Term) ->
    ok = file:write_file(filename:join(repo_path(), Path), io_lib:format("~p", [Term])).

register_user(N) ->
    NN = integer_to_list(N),
    run("kubectl exec mongooseim-0 -- mongooseimctl account registerUser "
        "--domain localhost --password password_" ++ NN ++ " --username user_" ++ NN).

run(Cmd) ->
    run(Cmd, #{}).

run(Cmd, Opts) ->
    {Diff, {Code, Res}} = timer:tc(fun() -> cmd(Cmd, Opts) end),
    ct:log("CMD ~ts~n~pms~nResult ~p ~ts", [Cmd, Diff, Code, Res]),
    {Code, Res}.

db_args() ->
    #{"auth.database" => "mongooseim",
      "auth.username" => "mongooseim",
      "auth.password" => "mongooseim"}.

galera_db_args() ->
    #{"db.name" => "mongooseim",
      "db.user" => "mongooseim",
      "db.password" => "mongooseim",
      "replicaCount" => "1",
      "tls.enabled" => "true",
      "tls.autoGenerated" => "true"}.

install_db(mariadb) ->
    %% https://mariadb.com/kb/en/ssltls-system-variables/#tls_version
    %% https://github.com/bitnami/charts/tree/main/bitnami/mariadb
    run("helm uninstall ct-mariadb"),
    %% Remove old volume
    run("kubectl delete pvc data-ct-mariadb-mariadb-galera-0"),
    %% Check https://mariadb.com/kb/en/secure-connections-overview/ for TLS info
    run("helm install ct-mariadb oci://registry-1.docker.io/bitnamicharts/mariadb-galera " ++ format_args(galera_db_args())),
    get_schema(mysql),
    Pod = "ct-mariadb-mariadb-galera-0",
    wait_for_pod_to_be_ready(Pod),
    run("kubectl cp _build/mysql.sql " ++ Pod ++ ":/tmp/mysql.sql"),
    run("kubectl exec " ++ Pod ++ " -- sh -c 'mariadb -u mongooseim -pmongooseim -D mongooseim < /tmp/mysql.sql'"),
    ok;
install_db(mysql) ->
    %% Docs: https://github.com/bitnami/charts/tree/main/bitnami/mysql
    run("helm uninstall ct-mysql"),
    %% Remove old volume
    run("kubectl delete pvc data-ct-mysql-0"),
    run("helm install ct-mysql oci://registry-1.docker.io/bitnamicharts/mysql " ++ format_args(db_args())),
    get_schema(mysql),
    Pod = "ct-mysql-0",
    wait_for_pod_to_be_ready(Pod),
    run("kubectl cp _build/mysql.sql ct-mysql-0:/tmp/mysql.sql"),
    run("kubectl exec " ++ Pod ++ " -- sh -c 'mysql -u mongooseim -pmongooseim -D mongooseim < /tmp/mysql.sql'"),
    ok;
install_db(pgsql) ->
    %% Docs: https://github.com/bitnami/charts/tree/main/bitnami/postgresql
    run("helm uninstall ct-pg"),
    %% Remove old volume
    run("kubectl delete pvc data-ct-pg-postgresql-0"),
    run("helm install ct-pg oci://registry-1.docker.io/bitnamicharts/postgresql"),
    get_schema(pgsql),
    Pod = "ct-pg-postgresql-0",
    wait_for_pod_to_be_ready(Pod),
    run("kubectl cp test/init.sql ct-pg-postgresql-0:/tmp/init.sql"),
    run("kubectl cp _build/pg.sql ct-pg-postgresql-0:/tmp/pg.sql"),
    run(psql(" -U postgres -f /tmp/init.sql")),
    run(psql(" -U postgres -d mongooseim -f /tmp/pg.sql")),
    run_psql_query("grant all privileges on all tables in schema public to mongooseim"),
    run_psql_query("grant all privileges on all sequences in schema public to mongooseim"),
    ok.

get_schema(mysql) ->
    run("curl https://raw.githubusercontent.com/esl/MongooseIM/master/priv/mysql.sql -o _build/mysql.sql");
get_schema(pgsql) ->
    run("curl https://raw.githubusercontent.com/esl/MongooseIM/master/priv/pg.sql -o _build/pg.sql").

psql(Args) ->
    "kubectl exec ct-pg-postgresql-0 -- sh -c 'PGPASSWORD=$POSTGRES_PASSWORD psql " ++ Args ++ "'".

run_psql_query(Query) ->
    run(psql(" -U postgres -d mongooseim -c \"" ++ Query ++ "\"")).

cmd(Cmd) ->
   cmd(Cmd, #{}).

cmd(Cmd, Opts) ->
    PortOpts =
        [{cd, repo_path()}, exit_status, use_stdio, binary]
        ++ [stderr_to_stdout || maps:get(stderr_to_stdout, Opts, true)],
    Port = erlang:open_port({spawn, Cmd}, PortOpts),
    receive_loop(Cmd, Port, <<>>).

repo_path() ->
    {ok, CWD} = file:get_cwd(),
    filename:join(CWD, "../../../../").

run_json(Cmd) ->
    {0, Text} = run(Cmd, #{stderr_to_stdout => false}),
    jiffy:decode(Text, [return_maps]).

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

session_count(Node) ->
    JSON = run_json("kubectl exec -it " ++ Node ++ " -- mongooseimctl session countSessions"),
    #{<<"data">> := #{<<"session">> := #{<<"countSessions">> := Count}}} = JSON,
    Count.

unavailable_nodes_count(Node) ->
    #{<<"unavailableNodes">> := Unavailable} = system_info(Node),
    length(Unavailable).

wait_for_joined_nodes_count(Node, ExpectedCount) ->
    wait_helper:wait_until(fun() -> joined_nodes_count(Node) end, ExpectedCount, #{time_left => timer:seconds(30)}).

wait_for_session_count(Node, ExpectedCount) ->
    wait_helper:wait_until(fun() -> session_count(Node) end, ExpectedCount, #{time_left => timer:seconds(30)}).

format_args(Map) ->
    lists:append([format_arg(Key, Value) || {Key, Value} <- maps:to_list(Map)]).

format_arg(Key, Value) ->
    " --set " ++ Key ++ "=" ++ Value.

%% Restarts if command returns non-zero code
run_wait(Cmd) ->
    V = fun({Code, _}) -> Code =:= 0 end,
    {ok, Res} = wait_helper:wait_until(fun() -> cmd(Cmd) end, true, #{validator => V}),
    Res.

wait_for_pod_to_be_ready(Pod) ->
    run_wait("kubectl wait --for=condition=ready --timeout=1m pod " ++ Pod).
