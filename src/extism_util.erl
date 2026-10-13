-module(extism_util).

-export([
    to_bin/1,
    to_map/1,
    plugin_dir/0,
    plugin_path/1,
    kernel_path/0,
    wat_path/1,
    sha256/1,
    glob_match/2,
    host_allowed/2,
    hidden_export/1,
    plugin_exports/1
]).

-include("extism.hrl").

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) ->
    case unicode:characters_to_binary(L) of
        Bin when is_binary(Bin) -> Bin;
        _ -> list_to_binary(L)
    end;
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

to_map(Map) when is_map(Map) ->
    maps:from_list([{to_bin(K), to_bin(V)} || {K, V} <- maps:to_list(Map)]);
to_map(List) when is_list(List) ->
    maps:from_list([{to_bin(K), to_bin(V)} || {K, V} <- List]).

plugin_dir() ->
    filename:join(priv_dir(), "plugins").

plugin_path(Name) ->
    Base = to_bin(Name),
    File = case filename:extension(Base) of
        <<".wasm">> -> Base;
        _ -> <<Base/binary, ".wasm">>
    end,
    filename:join(plugin_dir(), File).

wat_path(Name) ->
    filename:join([priv_dir(), "wat", to_bin(Name)]).

kernel_path() ->
    filename:join(priv_dir(), "extism-runtime.wasm").

priv_dir() ->
    case code:priv_dir(extism) of
        {error, _} ->
            filename:join(
                filename:dirname(filename:dirname(code:which(?MODULE))),
                "priv"
            );
        Dir ->
            Dir
    end.

sha256(Bin) when is_binary(Bin) ->
    list_to_binary(
        [io_lib:format("~2.16.0b", [B]) || <<B>> <= crypto:hash(sha256, Bin)]
    ).

host_allowed(_Host, undefined) -> true;
host_allowed(_Host, allow_all) -> true;
host_allowed(_Host, []) -> false;
host_allowed(Host, Hosts) when is_list(Hosts) ->
    H = to_bin(Host),
    lists:any(fun(Pat) -> glob_match(to_bin(Pat), H) end, Hosts).

glob_match(Pat, Host) when Pat =:= Host -> true;
glob_match(<<"*">>, _Host) -> true;
glob_match(Pat, Host) ->
    glob_match1(binary_to_list(Pat), binary_to_list(Host)).

glob_match1([], []) -> true;
glob_match1([], _) -> false;
glob_match1([$*], _) -> true;
glob_match1([$*, C | Rest], Subject) ->
    glob_match1([C | Rest], drop_until(C, Subject));
glob_match1([$? | Rest], [_ | Subject]) ->
    glob_match1(Rest, Subject);
glob_match1([C | Rest], [C | Subject]) ->
    glob_match1(Rest, Subject);
glob_match1(_, _) -> false.

drop_until(_C, []) -> [];
drop_until(C, [C | _] = Rest) -> Rest;
drop_until(C, [_ | Rest]) -> drop_until(C, Rest).

hidden_export(Name) ->
    lists:member(to_bin(Name), ?HIDDEN_EXPORTS).

plugin_exports(Inst) ->
    Raw = wasm:exports(Inst),
    Names = export_names(Raw),
    [N || N <- Names, not hidden_export(N)].

export_names(Map) when is_map(Map) ->
    [to_bin(K) || K <- maps:keys(Map)];
export_names(List) when is_list(List) ->
    [export_name(E) || E <- List];
export_names(_) ->
    [].

export_name({Name, _}) -> to_bin(Name);
export_name(Name) -> to_bin(Name).
