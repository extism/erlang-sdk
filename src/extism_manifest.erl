-module(extism_manifest).
%% Extism manifest loading: path, raw bytes, URL, JSON, or a map.

-export([resolve/1, resolve/2]).

-include("extism.hrl").

resolve(Source) ->
    resolve(Source, #{}).

resolve(Source, Opts) ->
    try do_resolve(Source, Opts) of
        {ok, _} = Ok -> Ok;
        {error, _} = E -> E
    catch
        C:R:S -> {error, {manifest_error, C, R, S}}
    end.

do_resolve(#{wasm := _} = Manifest, Opts) ->
    from_map(normalize_map(Manifest), Opts);
do_resolve(Map, Opts) when is_map(Map) ->
    case maps:is_key(<<"wasm">>, Map) orelse maps:is_key(wasm, Map) of
        true -> from_map(normalize_map(Map), Opts);
        false -> {error, {invalid_manifest, missing_wasm}}
    end;
do_resolve({wat, Wat}, _Opts) ->
    {ok, #{
        wasm => [{wat, extism_util:to_bin(Wat)}],
        config => #{},
        raw => #{type => wat}
    }};
do_resolve({url, Url}, Opts) ->
    fetch_wasm(extism_util:to_bin(Url), maps:get(headers, Opts, []), Opts);
do_resolve({plugin, Name}, Opts) ->
    Path = extism_util:plugin_path(Name),
    read_file(Path, Opts);
do_resolve(Bin, Opts) when is_binary(Bin) ->
    case extism_wasm_info:is_wasm(Bin) of
        true ->
            {ok, #{wasm => [{bytes, Bin}], config => #{}, raw => #{type => bytes}}};
        false ->
            case extism_wasm_info:is_wat(Bin) of
                true ->
                    {ok, #{wasm => [{wat, Bin}], config => #{}, raw => #{type => wat}}};
                false ->
                    case thoas:decode(Bin) of
                        {ok, Map} when is_map(Map) -> from_map(normalize_map(Map), Opts);
                        _ ->
                            %% Treat as a filesystem path or plugin name.
                            as_path(binary_to_list(Bin), Opts)
                    end
            end
    end;
do_resolve(Path, Opts) when is_list(Path) ->
    as_path(Path, Opts);
do_resolve(Name, Opts) when is_atom(Name) ->
    resolve({plugin, atom_to_binary(Name, utf8)}, Opts).

as_path(Path, Opts) ->
    case filelib:is_file(Path) of
        true ->
            read_file(Path, Opts);
        false ->
            Plugin = extism_util:plugin_path(Path),
            case filelib:is_file(Plugin) of
                true -> read_file(Plugin, Opts);
                false -> {error, {not_found, Path}}
            end
    end.

read_file(Path, Opts) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            case extism_wasm_info:is_wasm(Bin) of
                true ->
                    maybe_check_hash(Bin, maps:get(hash, Opts, undefined), #{
                        wasm => [{bytes, Bin}],
                        config => #{},
                        raw => #{type => file, path => extism_util:to_bin(Path)}
                    });
                false ->
                    case thoas:decode(Bin) of
                        {ok, Map} -> from_map(normalize_map(Map), Opts);
                        _ -> {error, {invalid_wasm, Path}}
                    end
            end;
        {error, Reason} ->
            {error, {file_error, Path, Reason}}
    end.

from_map(Manifest, Opts) ->
    WasmList = maps:get(<<"wasm">>, Manifest, []),
    case load_wasm_list(WasmList, Opts, []) of
        {ok, Modules} ->
            Config = config_of(Manifest),
            {ok, #{
                wasm => Modules,
                config => Config,
                allowed_hosts => allowed_hosts_of(Manifest),
                allowed_paths => allowed_paths_of(Manifest),
                memory => maps:get(<<"memory">>, Manifest, #{}),
                timeout_ms => maps:get(<<"timeout_ms">>, Manifest, undefined),
                raw => Manifest
            }};
        {error, _} = E ->
            E
    end.

load_wasm_list([], _Opts, Acc) -> {ok, lists:reverse(Acc)};
load_wasm_list([Item | Rest], Opts, Acc) ->
    case load_wasm_item(Item, Opts) of
        {ok, Mod} -> load_wasm_list(Rest, Opts, [Mod | Acc]);
        {error, _} = E -> E
    end.

load_wasm_item(#{<<"data">> := Data} = Item, _Opts) ->
    Bin = decode_data(Data),
    maybe_check_hash(Bin, maps:get(<<"hash">>, Item, undefined), {bytes, Bin});
load_wasm_item(#{<<"path">> := Path} = Item, _Opts) ->
    case file:read_file(extism_util:to_bin(Path)) of
        {ok, Bin} ->
            maybe_check_hash(Bin, maps:get(<<"hash">>, Item, undefined), {bytes, Bin});
        {error, Reason} ->
            {error, {file_error, Path, Reason}}
    end;
load_wasm_item(#{<<"url">> := Url} = Item, Opts) ->
    Headers = headers_of(maps:get(<<"headers">>, Item, #{})),
    case fetch_bytes(extism_util:to_bin(Url), Headers, Opts) of
        {ok, Bin} ->
            maybe_check_hash(Bin, maps:get(<<"hash">>, Item, undefined), {bytes, Bin});
        {error, _} = E ->
            E
    end;
load_wasm_item(_, _) ->
    {error, {invalid_wasm_source, unknown}}.

decode_data(Bin) when is_binary(Bin) ->
    case extism_wasm_info:is_wasm(Bin) of
        true -> Bin;
        false ->
            try base64:decode(Bin) of
                Decoded -> Decoded
            catch
                _:_ -> Bin
            end
    end;
decode_data(List) when is_list(List) ->
    decode_data(list_to_binary(List)).

maybe_check_hash(_Bin, undefined, Result) -> {ok, Result};
maybe_check_hash(Bin, Hash, Result) ->
    Actual = extism_util:sha256(Bin),
    Expect = string:lowercase(extism_util:to_bin(Hash)),
    case Actual =:= Expect of
        true -> {ok, Result};
        false -> {error, {hash_mismatch, Expect, Actual}}
    end.

fetch_wasm(Url, Headers, Opts) ->
    case fetch_bytes(Url, Headers, Opts) of
        {ok, Bin} ->
            {ok, #{wasm => [{bytes, Bin}], config => #{}, raw => #{type => url, url => Url}}};
        {error, _} = E ->
            E
    end.

fetch_bytes(Url, Headers, Opts) ->
    Timeout = maps:get(timeout, Opts, 30000),
    Hdrs = [{binary_to_list(K), binary_to_list(V)} || {K, V} <- Headers],
    case httpc:request(
        get,
        {binary_to_list(Url), Hdrs},
        [{timeout, Timeout}, {connect_timeout, Timeout}],
        [{body_format, binary}, {full_result, true}]
    ) of
        {ok, {{_, 200, _}, _, Body}} -> {ok, Body};
        {ok, {{_, Status, Reason}, _, _}} -> {error, {http_status, Status, Reason}};
        {error, Reason} -> {error, {http_error, Reason}}
    end.

headers_of(Map) when is_map(Map) ->
    [{extism_util:to_bin(K), extism_util:to_bin(V)} || {K, V} <- maps:to_list(Map)];
headers_of(_) ->
    [].

config_of(Manifest) ->
    case maps:get(<<"config">>, Manifest, #{}) of
        Map when is_map(Map) ->
            maps:from_list([{extism_util:to_bin(K), extism_util:to_bin(V)} || {K, V} <- maps:to_list(Map)]);
        _ ->
            #{}
    end.

allowed_hosts_of(Manifest) ->
    case maps:find(<<"allowed_hosts">>, Manifest) of
        error -> undefined;
        {ok, null} -> undefined;
        {ok, undefined} -> undefined;
        {ok, List} when is_list(List) -> [extism_util:to_bin(H) || H <- List]
    end.

allowed_paths_of(Manifest) ->
    case maps:get(<<"allowed_paths">>, Manifest, #{}) of
        Map when is_map(Map) ->
            maps:from_list([
                {extism_util:to_bin(K), extism_util:to_bin(V)}
                || {K, V} <- maps:to_list(Map)
            ]);
        _ ->
            #{}
    end.

normalize_map(Map) ->
    maps:from_list([normalize_pair(K, V) || {K, V} <- maps:to_list(Map)]).

normalize_pair(K, V) ->
    {extism_util:to_bin(K), normalize_val(V)}.

normalize_val(Map) when is_map(Map) -> normalize_map(Map);
normalize_val(List) when is_list(List) ->
    case io_lib:printable_unicode_list(List) of
        true -> extism_util:to_bin(List);
        false -> [normalize_val(X) || X <- List]
    end;
normalize_val(Other) -> Other.
