-module(extism_env).
%% Host-implemented `extism:host/env` functions (config, vars, HTTP, logging)
%% plus the legacy `env.extism_*` aliases used by older PDKs.

-export([imports/0, legacy_imports/1, update_state/1]).

-include("extism.hrl").

imports() ->
    #{
        {?EXTISM_ENV, <<"config_get">>} => fun config_get/2,
        {?EXTISM_ENV, <<"var_get">>} => fun var_get/2,
        {?EXTISM_ENV, <<"var_set">>} => fun var_set/2,
        {?EXTISM_ENV, <<"http_request">>} => fun http_request/2,
        {?EXTISM_ENV, <<"http_status_code">>} => fun http_status_code/2,
        {?EXTISM_ENV, <<"http_headers">>} => fun http_headers/2,
        {?EXTISM_ENV, <<"log_trace">>} => fun(Ctx, Args) -> log(trace, Ctx, Args) end,
        {?EXTISM_ENV, <<"log_debug">>} => fun(Ctx, Args) -> log(debug, Ctx, Args) end,
        {?EXTISM_ENV, <<"log_info">>} => fun(Ctx, Args) -> log(info, Ctx, Args) end,
        {?EXTISM_ENV, <<"log_warn">>} => fun(Ctx, Args) -> log(warn, Ctx, Args) end,
        {?EXTISM_ENV, <<"log_error">>} => fun(Ctx, Args) -> log(error, Ctx, Args) end,
        {?EXTISM_ENV, <<"get_log_level">>} => fun get_log_level/2
    }.

%% Older PDKs imported `env.extism_alloc` etc. Re-bind the kernel and host
%% functions under those names so kitchensink-style modules still load.
legacy_imports(Kernel) ->
    KernelAliases = lists:foldl(
        fun(Name, Acc) ->
            Acc#{{?EXTISM_LEGACY_ENV, <<"extism_", Name/binary>>} => kernel_fun(Kernel, Name)}
        end,
        #{},
        ?KERNEL_FUNS
    ),
    HostAliases = #{
        {?EXTISM_LEGACY_ENV, <<"extism_config_get">>} => fun config_get/2,
        {?EXTISM_LEGACY_ENV, <<"extism_var_get">>} => fun var_get/2,
        {?EXTISM_LEGACY_ENV, <<"extism_var_set">>} => fun var_set/2,
        {?EXTISM_LEGACY_ENV, <<"extism_http_request">>} => fun http_request/2,
        {?EXTISM_LEGACY_ENV, <<"extism_http_status_code">>} => fun http_status_code/2,
        {?EXTISM_LEGACY_ENV, <<"extism_log_info">>} => fun(Ctx, Args) -> log(info, Ctx, Args) end,
        {?EXTISM_LEGACY_ENV, <<"extism_log_debug">>} => fun(Ctx, Args) -> log(debug, Ctx, Args) end,
        {?EXTISM_LEGACY_ENV, <<"extism_log_warn">>} => fun(Ctx, Args) -> log(warn, Ctx, Args) end,
        {?EXTISM_LEGACY_ENV, <<"extism_log_error">>} => fun(Ctx, Args) -> log(error, Ctx, Args) end
    },
    maps:merge(KernelAliases, HostAliases).

kernel_fun(Kernel, Name) ->
    fun(_Ctx, Args) ->
        case wasm:call(Kernel, Name, Args) of
            {ok, Results} -> {ok, Results};
            {error, Err} -> {trap, Err}
        end
    end.

update_state(Fun) ->
    case get(extism_state) of
        #extism_state{} = S -> put(extism_state, Fun(S));
        _ -> ok
    end.

config_get(_Ctx, [Off]) ->
    Kernel = extism_current:kernel(),
    case extism_kernel:read_block(Kernel, Off) of
        {ok, Key} ->
            #extism_state{config = Cfg} = extism_current:state(),
            case maps:find(Key, Cfg) of
                {ok, Val} ->
                    case extism_kernel:write_block(Kernel, Val) of
                        {ok, Out} -> {ok, [Out]};
                        {error, Reason} -> {trap, Reason}
                    end;
                error ->
                    {ok, [0]}
            end;
        {error, Reason} ->
            {trap, Reason}
    end;
config_get(_Ctx, _) ->
    {ok, [0]}.

var_get(_Ctx, [Off]) ->
    Kernel = extism_current:kernel(),
    case extism_kernel:read_block(Kernel, Off) of
        {ok, Key} ->
            _ = extism_kernel:free(Kernel, Off),
            #extism_state{vars = Vars} = extism_current:state(),
            case maps:find(Key, Vars) of
                {ok, Val} ->
                    case extism_kernel:write_block(Kernel, Val) of
                        {ok, Out} -> {ok, [Out]};
                        {error, Reason} -> {trap, Reason}
                    end;
                error ->
                    {ok, [0]}
            end;
        {error, Reason} ->
            {trap, Reason}
    end;
var_get(_Ctx, _) ->
    {ok, [0]}.

var_set(_Ctx, [NameOff, 0]) ->
    Kernel = extism_current:kernel(),
    case extism_kernel:read_block(Kernel, NameOff) of
        {ok, Key} ->
            _ = extism_kernel:free(Kernel, NameOff),
            update_state(fun(#extism_state{vars = Vars} = S) ->
                S#extism_state{vars = maps:remove(Key, Vars)}
            end),
            {ok, []};
        {error, Reason} ->
            {trap, Reason}
    end;
var_set(_Ctx, [NameOff, ValueOff]) ->
    Kernel = extism_current:kernel(),
    case extism_kernel:read_block(Kernel, NameOff) of
        {ok, Key} ->
            case extism_kernel:read_block(Kernel, ValueOff) of
                {ok, Val} ->
                    _ = extism_kernel:free(Kernel, NameOff),
                    _ = extism_kernel:free(Kernel, ValueOff),
                    #extism_state{vars = Vars, max_var_bytes = Max} = extism_current:state(),
                    NewVars = Vars#{Key => Val},
                    Total = maps:fold(
                        fun(K, V, Acc) -> Acc + byte_size(K) + byte_size(V) end,
                        0,
                        NewVars
                    ),
                    case Total > Max of
                        true ->
                            {trap, var_store_full};
                        false ->
                            update_state(fun(S) -> S#extism_state{vars = NewVars} end),
                            {ok, []}
                    end;
                {error, Reason} ->
                    {trap, Reason}
            end;
        {error, Reason} ->
            {trap, Reason}
    end;
var_set(_Ctx, _) ->
    {ok, []}.

http_request(_Ctx, [ReqOff, BodyOff]) ->
    Kernel = extism_current:kernel(),
    case extism_kernel:read_block(Kernel, ReqOff) of
        {ok, ReqJSON} ->
            _ = extism_kernel:free(Kernel, ReqOff),
            Body = case BodyOff of
                0 -> <<>>;
                _ ->
                    case extism_kernel:read_block(Kernel, BodyOff) of
                        {ok, B} ->
                            _ = extism_kernel:free(Kernel, BodyOff),
                            B;
                        _ -> <<>>
                    end
            end,
            #extism_state{
                allowed_hosts = Allowed,
                max_http_response_bytes = Max,
                allow_http_headers = KeepHdrs,
                timeout_ms = Timeout
            } = extism_current:state(),
            case extism_http:request(ReqJSON, Body, #{
                allowed_hosts => Allowed,
                max_http_response_bytes => Max,
                timeout => Timeout
            }) of
                {ok, Status, Headers, RespBody} ->
                    update_state(fun(S) ->
                        S#extism_state{
                            last_http_status = Status,
                            last_http_headers = case KeepHdrs of
                                true -> Headers;
                                false -> #{}
                            end
                        }
                    end),
                    case extism_kernel:write_block(Kernel, RespBody) of
                        {ok, Off} -> {ok, [Off]};
                        {error, Reason} -> {trap, Reason}
                    end;
                {error, Reason} ->
                    update_state(fun(S) ->
                        S#extism_state{last_http_status = 0, last_http_headers = #{}}
                    end),
                    {trap, Reason}
            end;
        {error, Reason} ->
            {trap, Reason}
    end;
http_request(_Ctx, _) ->
    {ok, [0]}.

http_status_code(_Ctx, _) ->
    #extism_state{last_http_status = Status} = extism_current:state(),
    {ok, [Status]}.

http_headers(_Ctx, _) ->
    #extism_state{last_http_headers = Hdrs, allow_http_headers = Keep} =
        extism_current:state(),
    case Keep of
        false ->
            {ok, [0]};
        true ->
            JSON = iolist_to_binary(thoas:encode(Hdrs)),
            case extism_kernel:write_block(extism_current:kernel(), JSON) of
                {ok, Off} -> {ok, [Off]};
                {error, Reason} -> {trap, Reason}
            end
    end.

log(Level, _Ctx, [Off]) ->
    #extism_state{log_level = Min} = extism_current:state(),
    Kernel = extism_current:kernel(),
    case rank(Level) >= rank(Min) of
        true ->
            case extism_kernel:read_block(Kernel, Off) of
                {ok, Msg} ->
                    logger:log(logger_level(Level), "extism: ~s", [Msg]);
                _ ->
                    ok
            end;
        false ->
            ok
    end,
    _ = extism_kernel:free(Kernel, Off),
    {ok, []};
log(_Level, _Ctx, _) ->
    {ok, []}.

get_log_level(_Ctx, _) ->
    #extism_state{log_level = Level} = extism_current:state(),
    {ok, [rank(Level)]}.

rank(trace) -> 0;
rank(debug) -> 1;
rank(info) -> 2;
rank(warn) -> 3;
rank(error) -> 4;
rank(off) -> 5;
rank(_) -> 2.

logger_level(trace) -> debug;
logger_level(debug) -> debug;
logger_level(info) -> info;
logger_level(warn) -> warning;
logger_level(error) -> error.
