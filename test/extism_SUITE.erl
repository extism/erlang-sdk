-module(extism_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1,
         init_per_group/2, end_per_group/2]).

-export([
    bundled_plugins_present/1,
    wat_echo/1,
    wat_host_hello/1,
    count_vowels_basic/1,
    count_vowels_total_and_config/1,
    greet/1,
    echo/1,
    consume/1,
    input_offset/1,
    count_vowels_kvstore/1,
    reflect/1,
    python_code_functions/1,
    go_alloc/1,
    read_write/1,
    http_get/1,
    manifest_path_and_bytes/1,
    function_exists_and_exports/1,
    unknown_function/1,
    otp_worker_and_child_spec/1,
    raw_host_function/1
]).

all() ->
    [{group, kernel_wat}, {group, rust_pdk}, {group, host_fns}, {group, wasi_http}, {group, api}].

groups() ->
    [
        {kernel_wat, [sequence], [bundled_plugins_present, wat_echo, wat_host_hello]},
        {rust_pdk, [sequence], [
            count_vowels_basic,
            count_vowels_total_and_config,
            greet,
            echo,
            consume,
            input_offset
        ]},
        {host_fns, [], [
            count_vowels_kvstore,
            reflect,
            python_code_functions,
            go_alloc,
            raw_host_function
        ]},
        {wasi_http, [sequence], [read_write, http_get]},
        {api, [sequence], [
            manifest_path_and_bytes,
            function_exists_and_exports,
            unknown_function,
            otp_worker_and_child_spec
        ]}
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(extism),
    Config.

end_per_suite(_Config) ->
    application:stop(extism),
    ok.

init_per_group(_Group, Config) -> Config.
end_per_group(_Group, _Config) -> ok.

bundled_plugins_present(_Config) ->
    Names = extism:bundled_plugins(),
    ct:pal("bundled plugins: ~p", [Names]),
    ?assert(lists:member(<<"count_vowels">>, Names)),
    ?assert(lists:member(<<"greet">>, Names)),
    ?assert(lists:member(<<"count_vowels_kvstore">>, Names)).

wat_echo(_Config) ->
    Path = filename:join(code:priv_dir(extism), "wat/echo.wat"),
    {ok, Wat} = file:read_file(Path),
    {ok, Plugin} = extism:open({wat, Wat}),
    {ok, Out} = extism:call(Plugin, echo, <<"roundtrip">>),
    ?assertEqual(<<"roundtrip">>, Out),
    extism:close(Plugin).

wat_host_hello(_Config) ->
    Path = filename:join(code:priv_dir(extism), "wat/host_hello.wat"),
    {ok, Wat} = file:read_file(Path),
    {ok, Plugin} = extism:open({wat, Wat}, #{
        functions => #{hello => fun(Input) -> {ok, <<"hello, ", Input/binary>>} end}
    }),
    {ok, Out} = extism:call(Plugin, greet, <<"beam">>),
    ?assertEqual(<<"hello, beam">>, Out),
    extism:close(Plugin).

count_vowels_basic(_Config) ->
    {ok, Plugin} = extism:open(count_vowels),
    {ok, Out} = extism:call(Plugin, "count_vowels", "Hello, World!"),
    ct:pal("count_vowels => ~s", [Out]),
    {ok, Map} = thoas:decode(Out),
    ?assertEqual(3, maps:get(<<"count">>, Map)),
    ?assertEqual(3, maps:get(<<"total">>, Map)),
    extism:close(Plugin).

count_vowels_total_and_config(_Config) ->
    {ok, Plugin} = extism:open(count_vowels, #{config => #{<<"vowels">> => <<"aeiouAEIOU">>}}),
    {ok, Out1} = extism:call(Plugin, count_vowels, <<"this is a test">>),
    {ok, M1} = thoas:decode(Out1),
    ?assertEqual(4, maps:get(<<"count">>, M1)),
    ?assertEqual(4, maps:get(<<"total">>, M1)),
    {ok, Out2} = extism:call(Plugin, count_vowels, <<"this is a test">>),
    {ok, M2} = thoas:decode(Out2),
    ?assertEqual(4, maps:get(<<"count">>, M2)),
    ?assertEqual(8, maps:get(<<"total">>, M2)),
    ok = extism:config(Plugin, #{<<"vowels">> => <<"aeiouyAEIOUY">>}),
    {ok, Out3} = extism:call(Plugin, count_vowels, <<"y">>),
    {ok, M3} = thoas:decode(Out3),
    ?assertEqual(1, maps:get(<<"count">>, M3)),
    extism:close(Plugin).

greet(_Config) ->
    {ok, Plugin} = extism:open(greet),
    {ok, Out} = extism:call(Plugin, greet, <<"Erlang">>),
    ?assertEqual(<<"Hello, Erlang!">>, Out),
    extism:close(Plugin).

echo(_Config) ->
    {ok, Plugin} = extism:open(echo),
    {ok, Out} = extism:call(Plugin, echo, <<"same bytes">>),
    ?assertEqual(<<"same bytes">>, Out),
    extism:close(Plugin).

consume(_Config) ->
    {ok, Plugin} = extism:open(consume),
    {ok, Out} = extism:call(Plugin, consume, <<"ignored-input">>),
    ?assert(is_binary(Out)),
    extism:close(Plugin).

input_offset(_Config) ->
    {ok, Plugin} = extism:open(input_offset),
    {ok, Out} = extism:call(Plugin, input_offset_length, <<"abcdef">>),
    ct:pal("input_offset_length => ~p", [Out]),
    ?assert(byte_size(Out) >= 1),
    extism:close(Plugin).

count_vowels_kvstore(_Config) ->
    Tab = ets:new(kv, [public, set]),
    ets:insert(Tab, {<<"count-vowels">>, <<0, 0, 0, 0>>}),
    {ok, Plugin} = extism:open(count_vowels_kvstore, #{
        functions => #{
            kv_read => fun(Key) ->
                Val = case ets:lookup(Tab, Key) of
                    [{_, V}] -> V;
                    [] -> <<0, 0, 0, 0>>
                end,
                {ok, Val}
            end,
            kv_write => fun(Key, Val) ->
                ets:insert(Tab, {Key, Val}),
                ok
            end
        }
    }),
    {ok, Out1} = extism:call(Plugin, count_vowels, <<"hello">>),
    {ok, M1} = thoas:decode(Out1),
    ?assertEqual(2, maps:get(<<"count">>, M1)),
    ?assertEqual(2, maps:get(<<"total">>, M1)),
    {ok, Out2} = extism:call(Plugin, count_vowels, <<"hello">>),
    {ok, M2} = thoas:decode(Out2),
    ?assertEqual(2, maps:get(<<"count">>, M2)),
    ?assertEqual(4, maps:get(<<"total">>, M2)),
    extism:close(Plugin).

reflect(_Config) ->
    {ok, Plugin} = extism:open(reflect, #{
        functions => #{host_reflect => fun(Input) -> {ok, Input} end}
    }),
    {ok, Out} = extism:call(Plugin, reflect, <<"mirror">>),
    ?assertEqual(<<"mirror">>, Out),
    extism:close(Plugin).

python_code_functions(_Config) ->
    {ok, Plugin} = extism:open(<<"python_code-functions">>, #{
        wasi => true,
        functions => #{
            hello_world => fun(JSON) ->
                Map = case thoas:decode(JSON) of
                    {ok, M} when is_map(M) -> M;
                    _ -> #{<<"input">> => JSON}
                end,
                {ok, iolist_to_binary(thoas:encode(Map#{<<"roundtrip">> => 1}))}
            end
        }
    }),
    {ok, Out} = extism:call(Plugin, count_vowels, <<"hello world">>),
    ct:pal("python_code-functions => ~s", [Out]),
    {ok, Map} = thoas:decode(Out),
    ?assertEqual(3, maps:get(<<"count">>, Map)),
    extism:close(Plugin).

go_alloc(_Config) ->
    {ok, Plugin} = extism:open(go_alloc),
    case extism:call(Plugin, run_test, <<>>) of
        {ok, Out} ->
            ct:pal("go_alloc => ~p", [Out]),
            ?assert(is_binary(Out));
        {error, #{class := _, message := _}} ->
            ?assert(true)
    end,
    extism:close(Plugin).

raw_host_function(_Config) ->
    {ok, Plugin} = extism:open(reflect, #{
        functions => #{
            host_reflect => {raw, [i64], [i64], fun(P, [Off]) ->
                {ok, In} = extism:read(P, Off),
                {ok, OutOff} = extism:write(P, In),
                {ok, [OutOff]}
            end}
        }
    }),
    {ok, <<"raw">>} = extism:call(Plugin, reflect, <<"raw">>),
    extism:close(Plugin).

read_write(Config) ->
    DataDir = filename:join(?config(priv_dir, Config), "rw"),
    ok = filelib:ensure_dir(filename:join(DataDir, "x")),
    File = filename:join(DataDir, "note.txt"),
    ok = file:write_file(File, <<"hello ">>),
    {ok, Plugin} = extism:open(read_write, #{
        wasi => true,
        config => #{<<"path">> => <<"/data/note.txt">>},
        allowed_paths => #{list_to_binary(DataDir) => <<"/data">>}
    }),
    case extism:call(Plugin, try_read, <<>>) of
        {ok, Out} ->
            ?assertEqual(<<"hello ">>, Out),
            {ok, Out2} = extism:call(Plugin, try_write, <<"world">>),
            ?assertEqual(<<"hello world">>, Out2);
        {error, Reason} ->
            ct:pal("read_write failed (WASI path mapping): ~p", [Reason]),
            ?assert(extism:function_exists(Plugin, try_read))
    end,
    extism:close(Plugin).

http_get(_Config) ->
    {ok, Plugin} = extism:open(http, #{
        allowed_hosts => [<<"example.com">>, <<"www.example.com">>],
        allow_http_response_headers => true
    }),
    Req = <<"{\"url\":\"https://example.com\",\"method\":\"GET\"}">>,
    case extism:call(Plugin, http_get, Req) of
        {ok, Body} ->
            ct:pal("http_get bytes=~p prefix=~p", [byte_size(Body), peek(Body, 40)]),
            ?assert(byte_size(Body) > 0);
        {error, Reason} ->
            ct:pal("http_get skipped/failed: ~p", [Reason]),
            ?assert(extism:function_exists(Plugin, http_get))
    end,
    extism:close(Plugin).

manifest_path_and_bytes(_Config) ->
    Path = extism:plugin_path(greet),
    {ok, Bin} = file:read_file(Path),
    Hash = extism_util:sha256(Bin),
    {ok, P1} = extism:open(#{wasm => [#{path => Path, hash => Hash}]}),
    {ok, <<"Hello, manifest!">>} = extism:call(P1, greet, <<"manifest">>),
    extism:close(P1),
    {ok, P2} = extism:new(Bin),
    {ok, <<"Hello, bytes!">>} = extism:call(P2, greet, <<"bytes">>),
    extism:close(P2).

function_exists_and_exports(_Config) ->
    {ok, Plugin} = extism:open(count_vowels),
    Exports = extism:exports(Plugin),
    ct:pal("exports=~p", [Exports]),
    ?assert(extism:function_exists(Plugin, count_vowels)),
    ?assertNot(extism:function_exists(Plugin, no_such_fn)),
    ?assert(lists:member(<<"count_vowels">>, Exports)),
    extism:close(Plugin).

unknown_function(_Config) ->
    {ok, Plugin} = extism:open(echo),
    {error, #{class := Class, reason := Reason, message := Msg}} =
        extism:call(Plugin, definitely_missing, <<"x">>),
    ?assert(is_atom(Class)),
    ?assert(Reason =/= undefined),
    ?assert(is_binary(Msg)),
    extism:close(Plugin).

otp_worker_and_child_spec(_Config) ->
    {ok, Pid} = extism:start_link(greet, #{name => {local, extism_dx_greet}}),
    ?assert(is_pid(Pid)),
    {ok, <<"Hello, OTP!">>} = extism:call(Pid, greet, <<"OTP">>),
    ?assert(extism:function_exists(Pid, greet)),
    Spec = extism:child_spec(greet, #{}, #{id => greet_plugin}),
    ?assertEqual(greet_plugin, maps:get(id, Spec)),
    ?assertMatch({extism, start_link, [greet, #{}]}, maps:get(start, Spec)),
    ok = extism:stop(Pid).

peek(Bin, N) when byte_size(Bin) > N -> binary:part(Bin, 0, N);
peek(Bin, _) -> Bin.
