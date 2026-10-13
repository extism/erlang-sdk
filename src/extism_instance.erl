-module(extism_instance).
%% Process-owned plugin handle. The caller (or a worker) instantiates
%% kernel+guest here; nothing is a gen_server.

-export([
    open/2,
    close/1,
    call/4,
    function_exists/2,
    config/2,
    reset/1,
    error/1,
    exports/1,
    allow_http_response_headers/1,
    read/2,
    write/2,
    host_context/1,
    is_handle/1
]).

-include("extism.hrl").

open(Source, Opts) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, _} = application:ensure_all_started(inets),
    Ref = make_ref(),
    Handle = #{extism => plugin, ref => Ref},
    case extism_manifest:resolve(Source, Opts) of
        {ok, Manifest} ->
            case build(Handle, Manifest, Opts) of
                {ok, State} ->
                    put({extism, Ref}, State),
                    maybe_init_runtime(State#extism_state.plugin),
                    {ok, Handle};
                {error, _} = E ->
                    E
            end;
        {error, Reason} ->
            extism_error:wrap(manifest, Reason)
    end.

close(#{extism := plugin, ref := Ref} = Handle) ->
    case take_state(Handle) of
        {ok, #extism_state{kernel = K, plugin = P}} ->
            safe_destroy(P),
            safe_destroy(K),
            erase({extism, Ref}),
            ok;
        {error, _} ->
            ok
    end.

call(Handle, Func, Input, Opts) ->
    case get_state(Handle) of
        {error, _} = E ->
            E;
        {ok, #extism_state{plugin = Plugin, kernel = Kernel} = State} ->
            _ = extism_kernel:reset(Kernel),
            case extism_kernel:input_set(Kernel, Input) of
                {ok, _} ->
                    CallState = State#extism_state{
                        host_context = maps:get(host_context, Opts, undefined),
                        last_error = undefined,
                        last_http_status = 0
                    },
                    put({extism, ref(Handle)}, CallState),
                    put(extism_state, CallState),
                    put(extism_handle, Handle),
                    CallOpts = inst_opts(State#extism_state.fuel, State#extism_state.max_depth),
                    Result = case maps:size(CallOpts) of
                        0 -> wasm:call(Plugin, Func, []);
                        _ -> wasm:call(Plugin, Func, [], CallOpts)
                    end,
                    NewState = case get(extism_state) of
                        #extism_state{} = S -> S;
                        _ -> CallState
                    end,
                    erase(extism_state),
                    erase(extism_handle),
                    put({extism, ref(Handle)}, NewState),
                    handle_call_result(Handle, NewState, Kernel, Result);
                {error, Reason} ->
                    extism_error:wrap(host, input_set_failed, Reason)
            end
    end.

function_exists(Handle, Func) ->
    case get_state(Handle) of
        {ok, #extism_state{exports = Es}} -> lists:member(extism_util:to_bin(Func), Es);
        {error, _} -> false
    end.

config(Handle, Config) ->
    with_state(Handle, fun(#extism_state{config = Cfg} = S) ->
        {ok, S#extism_state{config = maps:merge(Cfg, extism_util:to_map(Config))}}
    end).

reset(Handle) ->
    with_state(Handle, fun(#extism_state{kernel = K} = S) ->
        _ = extism_kernel:reset(K),
        {ok, S#extism_state{last_error = undefined}}
    end).

error(Handle) ->
    case get_state(Handle) of
        {ok, #extism_state{last_error = Err}} -> Err;
        {error, _} -> undefined
    end.

exports(Handle) ->
    case get_state(Handle) of
        {ok, #extism_state{exports = Es}} -> Es;
        {error, _} -> []
    end.

allow_http_response_headers(Handle) ->
    with_state(Handle, fun(S) ->
        {ok, S#extism_state{allow_http_headers = true}}
    end).

read(Handle, Off) ->
    case get_state(Handle) of
        {ok, #extism_state{kernel = K}} -> extism_kernel:read_block(K, Off);
        {error, _} = E -> E
    end.

write(Handle, Bin) ->
    case get_state(Handle) of
        {ok, #extism_state{kernel = K}} ->
            extism_kernel:write_block(K, extism_util:to_bin(Bin));
        {error, _} = E ->
            E
    end.

host_context(Handle) ->
    case get_state(Handle) of
        {ok, #extism_state{host_context = Ctx}} -> Ctx;
        {error, _} -> undefined
    end.

is_handle(#{extism := plugin, ref := _}) -> true;
is_handle(_) -> false.

%%%----------------------------------------------------------------
%%% build
%%%----------------------------------------------------------------

build(Handle, Manifest, Opts) ->
    case extism_kernel:load() of
        {ok, KernelMod} ->
            case extism_kernel:instantiate(KernelMod) of
                {ok, Kernel} ->
                    case load_plugin_mod(Manifest) of
                        {ok, PluginMod, WasmBytes} ->
                            instantiate_plugin(Handle, Manifest, Opts, KernelMod, Kernel, PluginMod, WasmBytes);
                        {error, Reason} ->
                            safe_destroy(Kernel),
                            extism_error:wrap(link, Reason)
                    end;
                {error, Reason} ->
                    extism_error:wrap(link, kernel_instantiate_failed, Reason)
            end;
        {error, Reason} ->
            extism_error:wrap(link, kernel_load_failed, Reason)
    end.

load_plugin_mod(#{wasm := [{bytes, Bin} | _]}) ->
    case wasm:load(Bin) of
        {ok, Mod} -> {ok, Mod, Bin};
        {error, Reason} -> {error, {plugin_load_failed, Reason}}
    end;
load_plugin_mod(#{wasm := [{wat, Wat} | _]}) ->
    case wasm:compile({wat, Wat}) of
        {ok, Mod} -> {ok, Mod, Wat};
        {error, Reason} -> {error, {wat_compile_failed, Reason}}
    end;
load_plugin_mod(#{wasm := []}) ->
    {error, empty_manifest};
load_plugin_mod(_) ->
    {error, {invalid_manifest, no_wasm}}.

instantiate_plugin(Handle, Manifest, Opts, KernelMod, Kernel, PluginMod, WasmBytes) ->
    Functions = maps:get(functions, Opts, maps:get(host_functions, Opts, #{})),
    Wasi = wasi_opt(Opts, WasmBytes),
    Config = maps:merge(
        maps:get(config, Manifest, #{}),
        extism_util:to_map(maps:get(config, Opts, #{}))
    ),
    AllowedHosts = case maps:get(allowed_hosts, Opts, undefined) of
        undefined -> maps:get(allowed_hosts, Manifest, undefined);
        AH -> AH
    end,
    AllowedPaths = maps:merge(
        maps:get(allowed_paths, Manifest, #{}),
        maps:get(allowed_paths, Opts, #{})
    ),
    Memory = maps:get(memory, Manifest, #{}),
    MaxHttp = first_int([
        maps:get(max_http_response_bytes, Opts, undefined),
        maps:get(<<"max_http_response_bytes">>, Memory, undefined)
    ], 50 * 1024 * 1024),
    MaxVar = first_int([
        maps:get(max_var_bytes, Opts, undefined),
        maps:get(<<"max_var_bytes">>, Memory, undefined)
    ], 1024 * 1024),
    Timeout = first_int([
        maps:get(timeout, Opts, undefined),
        maps:get(timeout_ms, Manifest, undefined)
    ], 30000),
    Fuel = maps:get(fuel, Opts, undefined),
    Depth = maps:get(max_depth, Opts, undefined),
    LogLevel = maps:get(log_level, Opts, info),
    Imports = build_imports(Handle, Kernel, Functions, Wasi, AllowedPaths, WasmBytes),
    InstOpts = inst_opts(Fuel, Depth),
    case wasm:instantiate(PluginMod, Imports, InstOpts) of
        {ok, Plugin} ->
            Exports = case extism_util:plugin_exports(Plugin) of
                [] ->
                    [Name || {Name, func} <- extism_wasm_info:exports(WasmBytes),
                             not extism_util:hidden_export(Name)];
                Es -> Es
            end,
            {ok, #extism_state{
                kernel_mod = KernelMod,
                kernel = Kernel,
                plugin_mod = PluginMod,
                plugin = Plugin,
                source_hash = extism_util:sha256(
                    case WasmBytes of B when is_binary(B) -> B; _ -> <<>> end
                ),
                config = Config,
                functions = Functions,
                wasi = Wasi,
                allowed_hosts = AllowedHosts,
                allowed_paths = AllowedPaths,
                max_http_response_bytes = MaxHttp,
                max_var_bytes = MaxVar,
                allow_http_headers = maps:get(allow_http_response_headers, Opts, false),
                log_level = LogLevel,
                fuel = Fuel,
                max_depth = Depth,
                timeout_ms = Timeout,
                exports = Exports
            }};
        {error, Reason} ->
            safe_destroy(Kernel),
            extism_error:wrap(link, plugin_instantiate_failed, Reason)
    end.

build_imports(Handle, Kernel, Functions, Wasi, AllowedPaths, WasmBytes) ->
    KernelImps = extism_kernel:env_externs(Kernel),
    HostImps = extism_env:imports(),
    LegacyImps = extism_env:legacy_imports(Kernel),
    UserImps = extism_function:to_imports(Functions, Handle),
    WasiImps = wasi_imports(Wasi, AllowedPaths, WasmBytes),
    lists:foldl(fun maps:merge/2, #{}, [WasiImps, LegacyImps, KernelImps, HostImps, UserImps]).

wasi_imports(false, _, _) -> #{};
wasi_imports(true, Paths, WasmBytes) ->
    wasi_imports(#{}, Paths, WasmBytes);
wasi_imports(Cfg, Paths, WasmBytes) when is_map(Cfg) ->
    case needs_wasi(WasmBytes) orelse Cfg =/= #{} orelse Paths =/= #{} of
        false ->
            #{};
        true ->
            Dirs = dirs_of(Paths),
            WasiCfg = maps:merge(
                #{
                    clocks => [monotonic, realtime],
                    random => strong,
                    args => maps:get(args, Cfg, []),
                    env => maps:get(env, Cfg, #{})
                },
                maps:without([args, env], Cfg)
            ),
            WasiCfg2 = case Dirs of
                [] -> WasiCfg;
                _ -> WasiCfg#{dirs => Dirs}
            end,
            maps:merge(
                unwrap_imports(wasi_preview1:imports(WasiCfg2)),
                unwrap_imports(wasi_preview1:imports(WasiCfg2, <<"wasi_unstable">>))
            )
    end.

needs_wasi(Bin) when is_binary(Bin) -> extism_wasm_info:needs_wasi(Bin);
needs_wasi(_) -> false.

unwrap_imports({ok, Map}) -> Map;
unwrap_imports(Map) when is_map(Map) -> Map.

dirs_of(Paths) when map_size(Paths) =:= 0 -> [];
dirs_of(Paths) ->
    maps:fold(
        fun(Host, Guest, Acc) ->
            [{extism_util:to_bin(Guest), binary_to_list(extism_util:to_bin(Host)), write} | Acc]
        end,
        [],
        Paths
    ).

wasi_opt(Opts, WasmBytes) ->
    case maps:get(wasi, Opts, undefined) of
        undefined ->
            extism_wasm_info:needs_wasi(
                case WasmBytes of B when is_binary(B) -> B; _ -> <<>> end
            );
        Other -> Other
    end.

inst_opts(undefined, undefined) -> #{};
inst_opts(Fuel, undefined) -> #{fuel => Fuel};
inst_opts(undefined, Depth) -> #{max_depth => Depth};
inst_opts(Fuel, Depth) -> #{fuel => Fuel, max_depth => Depth}.

first_int(List, Default) ->
    case lists:dropwhile(fun(X) -> X =:= undefined end, List) of
        [N | _] when is_integer(N) -> N;
        _ -> Default
    end.

maybe_init_runtime(Plugin) ->
    _ = try_call(Plugin, <<"_initialize">>, []),
    _ = try_call(Plugin, <<"__wasm_call_ctors">>, []),
    ok.

try_call(Plugin, Name, Args) ->
    case wasm:call(Plugin, Name, Args) of
        {ok, _} = Ok -> Ok;
        {error, _} -> ok
    end.

handle_call_result(Handle, State, Kernel, {ok, Results}) ->
    case extism_kernel:error(Kernel) of
        Bin when is_binary(Bin), byte_size(Bin) > 0 ->
            put({extism, ref(Handle)}, State#extism_state{last_error = Bin}),
            {error, extism_error:new(plugin, plugin_error, Bin)};
        _ ->
            case Results of
                [Code] when is_integer(Code), Code =/= 0 ->
                    Msg = case extism_kernel:error(Kernel) of
                        undefined -> <<"plugin returned non-zero status">>;
                        E -> E
                    end,
                    put({extism, ref(Handle)}, State#extism_state{last_error = Msg}),
                    {error, extism_error:new(plugin, plugin_status, Msg, #{status => Code})};
                _ ->
                    case extism_kernel:output(Kernel) of
                        {ok, Out} ->
                            put({extism, ref(Handle)}, State#extism_state{last_error = undefined}),
                            {ok, Out};
                        {error, Reason} ->
                            extism_error:wrap(host, output_failed, Reason)
                    end
            end
    end;
handle_call_result(Handle, State, Kernel, {error, Reason}) ->
    {Class, ErrAtom, Msg} = case extism_kernel:error(Kernel) of
        ErrBin when is_binary(ErrBin), byte_size(ErrBin) > 0 ->
            {plugin, plugin_error, ErrBin};
        _ ->
            {class_of(Reason), reason_of(Reason), message_of(Reason)}
    end,
    put({extism, ref(Handle)}, State#extism_state{last_error = Msg}),
    {error, extism_error:new(Class, ErrAtom, Msg, Reason)}.

class_of(#{class := C}) -> C;
class_of(_) -> trap.

reason_of(#{kind := K}) -> K;
reason_of(#{reason := R}) -> R;
reason_of(_) -> trap.

message_of(#{msg := M}) -> extism_util:to_bin(M);
message_of(#{message := M}) -> extism_util:to_bin(M);
message_of(Other) -> extism_util:to_bin(io_lib:format("~p", [Other])).

ref(#{ref := Ref}) -> Ref.

get_state(#{extism := plugin, ref := Ref}) ->
    case get({extism, Ref}) of
        #extism_state{} = S -> {ok, S};
        _ ->
            {error, extism_error:new(host, stale_plugin,
                <<"plugin is closed or not owned by this process">>)}
    end;
get_state(_) ->
    {error, extism_error:new(host, bad_plugin, <<"not an extism plugin handle">>)}.

take_state(Handle) -> get_state(Handle).

with_state(Handle, Fun) ->
    case get_state(Handle) of
        {ok, State} ->
            case Fun(State) of
                {ok, New} ->
                    put({extism, ref(Handle)}, New),
                    ok;
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

safe_destroy(undefined) -> ok;
safe_destroy(Inst) ->
    try wasm:destroy(Inst) of
        _ -> ok
    catch
        _:_ -> ok
    end.
