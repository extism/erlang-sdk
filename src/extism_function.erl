-module(extism_function).
%% Host-function descriptions.
%%
%% Prefer a map of funs on `extism:open/2`:
%%
%%     #{functions => #{
%%         hello => fun(Input) -> {ok, <<"hello, ", Input/binary>>} end,
%%         kv_write => fun(Key, Val) -> ok end
%%     }}
%%
%% A plain fun is bytes-in / bytes-out. Arity is the number of Extism
%% memory handles. Low-level WASM values use `{raw, Params, Results, Fun}`.

-export([
    new/3, new/4, new/5,
    from_bytes/2, from_bytes/3,
    set_namespace/2,
    to_imports/1, to_imports/2
]).

-include("extism.hrl").

-export_type([host_function/0]).
-type host_function() :: #extism_function{}.

new(Name, Params, Results) ->
    new(Name, Params, Results, fun(_, Args, _) -> {ok, Args} end, undefined).

new(Name, Params, Results, Fun) ->
    new(Name, Params, Results, Fun, undefined).

new(Name, Params, Results, Fun, UserData) when is_function(Fun) ->
    #extism_function{
        name = extism_util:to_bin(Name),
        namespace = ?EXTISM_USER,
        params = [norm_type(T) || T <- Params],
        results = [norm_type(T) || T <- Results],
        callback = Fun,
        user_data = UserData
    }.

from_bytes(Name, Fun) ->
    from_bytes(Name, Fun, undefined).

from_bytes(Name, Fun, UserData) ->
    new(Name, [ptr], [ptr], wrap_legacy_bytes(Fun), UserData).

set_namespace(#extism_function{} = F, Ns) ->
    F#extism_function{namespace = extism_util:to_bin(Ns)}.

to_imports(Functions) ->
    to_imports(Functions, undefined).

to_imports(Functions, Handle) when is_map(Functions) ->
    maps:fold(
        fun(K, V, Acc) ->
            {Ns, Name} = key(K),
            Acc#{{Ns, Name} => wrap(Handle, V)}
        end,
        #{},
        Functions
    );
to_imports(Functions, Handle) when is_list(Functions) ->
    lists:foldl(fun(Item, Acc) -> add_import(Handle, Item, Acc) end, #{}, Functions).

add_import(Handle, #extism_function{name = Name, namespace = Ns, callback = Fun, user_data = UD}, Acc) ->
    Acc#{{Ns, Name} => wrap(Handle, {record, Fun, UD})};
add_import(Handle, {{Ns, Name}, Fun}, Acc) ->
    Acc#{{extism_util:to_bin(Ns), extism_util:to_bin(Name)} => wrap(Handle, Fun)};
add_import(Handle, {Name, Fun}, Acc) ->
    Acc#{{?EXTISM_USER, extism_util:to_bin(Name)} => wrap(Handle, Fun)}.

key({Ns, Name}) -> {extism_util:to_bin(Ns), extism_util:to_bin(Name)};
key(Name) -> {?EXTISM_USER, extism_util:to_bin(Name)}.

wrap(Handle, Fun) when is_function(Fun) ->
    {arity, N} = erlang:fun_info(Fun, arity),
    wrap_bytes(Handle, Fun, N);
wrap(Handle, {host, Fun}) when is_function(Fun) ->
    wrap_host(Handle, Fun);
wrap(Handle, {raw, Params, Results, Fun}) when is_function(Fun) ->
    _ = {Params, Results},
    wrap_raw(Handle, Fun);
wrap(Handle, {record, Fun, UD}) ->
    wrap_record(Handle, Fun, UD);
wrap(Handle, {M, F, A}) ->
    wrap(Handle, fun(P, Args) -> apply(M, F, A ++ [P, Args]) end).

%% Bytes-in / bytes-out. Arity is the number of guest handles.
wrap_bytes(Handle, Fun, Arity) ->
    fun(_Ctx, Args) ->
        Bins = [read_arg(Handle, A) || A <- Args],
        Taken = lists:sublist(Bins, Arity),
        Result = apply(Fun, Taken ++ lists:duplicate(max(0, Arity - length(Taken)), <<>>)),
        bytes_result(Handle, Result)
    end.

%% fun(Plugin, InputBin) or fun(Plugin, [Bins]).
wrap_host(Handle, Fun) ->
    fun(_Ctx, Args) ->
        Bins = [read_arg(Handle, A) || A <- Args],
        {arity, N} = erlang:fun_info(Fun, arity),
        Result = case N of
            1 -> Fun(hd_or_empty(Bins));
            2 ->
                case Bins of
                    [One] -> Fun(Handle, One);
                    _ -> Fun(Handle, Bins)
                end;
            3 -> Fun(Handle, Bins, undefined);
            _ -> Fun(Handle, Bins)
        end,
        bytes_result(Handle, Result)
    end.

wrap_raw(Handle, Fun) ->
    fun(_Ctx, Args) ->
        normalize_raw(apply_raw(Fun, Handle, Args))
    end.

wrap_record(Handle, Fun, UD) ->
    fun(Ctx, Args) ->
        Current = #{
            ctx => Ctx,
            plugin => Handle,
            kernel => extism_current:kernel(),
            host_context => extism_current:host_context()
        },
        normalize_raw(apply_host(Fun, Current, Args, UD))
    end.

apply_raw(Fun, Handle, Args) ->
    {arity, N} = erlang:fun_info(Fun, arity),
    case N of
        2 -> Fun(Handle, Args);
        3 -> Fun(Handle, Args, undefined);
        1 -> Fun(Args);
        0 -> Fun()
    end.

apply_host(Fun, Current, Args, UD) ->
    case erlang:fun_info(Fun, arity) of
        {arity, 3} -> Fun(Current, Args, UD);
        {arity, 2} -> Fun(Current, Args);
        {arity, 1} -> Fun(Args);
        {arity, 0} -> Fun()
    end.

bytes_result(Handle, {ok, Bin}) when is_binary(Bin) ->
    case write_arg(Handle, Bin) of
        {ok, Off} -> {ok, [Off]};
        {error, Reason} -> {trap, Reason}
    end;
bytes_result(_Handle, ok) ->
    {ok, []};
bytes_result(_Handle, {ok, []}) ->
    {ok, []};
bytes_result(Handle, {ok, List}) when is_list(List) ->
    case lists:all(fun is_binary/1, List) of
        true ->
            Offs = [begin {ok, O} = write_arg(Handle, B), O end || B <- List],
            {ok, Offs};
        false ->
            {ok, List}
    end;
bytes_result(Handle, Bin) when is_binary(Bin) ->
    bytes_result(Handle, {ok, Bin});
bytes_result(_Handle, {trap, _} = T) ->
    T;
bytes_result(_Handle, {error, Reason}) ->
    {trap, Reason};
bytes_result(_Handle, Other) ->
    {ok, [Other]}.

normalize_raw({ok, Results}) when is_list(Results) -> {ok, Results};
normalize_raw({ok, Result}) -> {ok, [Result]};
normalize_raw({trap, _} = T) -> T;
normalize_raw({error, Reason}) -> {trap, Reason};
normalize_raw(Results) when is_list(Results) -> {ok, Results};
normalize_raw(Other) -> {ok, [Other]}.

read_arg(_Handle, Off) when is_integer(Off) ->
    case extism_current:read(Off) of
        {ok, Bin} -> Bin;
        _ -> <<>>
    end;
read_arg(_, Other) ->
    Other.

write_arg(_Handle, Bin) ->
    extism_current:write(Bin).

hd_or_empty([H | _]) -> H;
hd_or_empty([]) -> <<>>.

wrap_legacy_bytes(Fun) ->
    fun(Current, Args, UD) ->
        Bins = [begin
            case extism_current:read(A) of
                {ok, B} -> B;
                _ -> <<>>
            end
        end || A <- Args],
        Out = case erlang:fun_info(Fun, arity) of
            {arity, 3} -> Fun(Current, Bins, UD);
            {arity, 2} -> Fun(Current, Bins);
            {arity, 1} -> Fun(Bins)
        end,
        case Out of
            {ok, Bin} when is_binary(Bin) ->
                {ok, Off} = extism_current:write(Bin),
                {ok, [Off]};
            Bin when is_binary(Bin) ->
                {ok, Off} = extism_current:write(Bin),
                {ok, [Off]};
            Other ->
                normalize_raw(Other)
        end
    end.

norm_type(ptr) -> i64;
norm_type(i32) -> i32;
norm_type(i64) -> i64;
norm_type(f32) -> f32;
norm_type(f64) -> f64;
norm_type(v128) -> v128;
norm_type(Other) -> Other.
