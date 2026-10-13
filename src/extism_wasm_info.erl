-module(extism_wasm_info).

%% Lightweight WASM binary inspector. Used to list imports/exports before
%% instantiation so the SDK can wire Extism env, user host functions, and WASI.

-export([is_wasm/1, is_wat/1, is_manifest/1, imports/1, exports/1, needs_wasi/1]).

is_wasm(<<0, $a, $s, $m, _/binary>>) -> true;
is_wasm(_) -> false.

is_wat(Bin) when is_binary(Bin) ->
    not is_wasm(Bin) andalso
        (binary:match(Bin, <<"(module">>) =/= nomatch orelse
         binary:match(Bin, <<"(module ">>) =/= nomatch);
is_wat(_) -> false.

is_manifest(Bin) when is_binary(Bin) ->
    not is_wasm(Bin) andalso
        (binary:match(Bin, <<"\"wasm\"">>) =/= nomatch orelse
         binary:match(Bin, <<"wasm">>) =/= nomatch);
is_manifest(_) -> false.

needs_wasi(Bin) ->
    lists:any(
        fun({Mod, _, _}) ->
            Mod =:= <<"wasi_snapshot_preview1">> orelse Mod =:= <<"wasi_unstable">>
        end,
        imports(Bin)
    ).

imports(Bin) when is_binary(Bin) ->
    case section(Bin, 2) of
        {ok, Payload} -> parse_import_section(Payload);
        error -> []
    end.

exports(Bin) when is_binary(Bin) ->
    case section(Bin, 7) of
        {ok, Payload} -> parse_export_section(Payload);
        error -> []
    end.

section(<<0, $a, $s, $m, _:32, Rest/binary>>, Id) ->
    find_section(Rest, Id);
section(_, _) ->
    error.

find_section(<<>>, _) -> error;
find_section(Bin, Id) ->
    {Sid, AfterId} = read_leb(Bin),
    {Len, AfterLen} = read_leb(AfterId),
    <<Payload:Len/binary, Rest/binary>> = AfterLen,
    case Sid of
        Id -> {ok, Payload};
        _ -> find_section(Rest, Id)
    end.

parse_import_section(Payload) ->
    {Count, Rest} = read_leb(Payload),
    parse_imports(Rest, Count, []).

parse_imports(_Bin, 0, Acc) -> lists:reverse(Acc);
parse_imports(Bin, N, Acc) ->
    {Mod, B1} = read_name(Bin),
    {Field, B2} = read_name(B1),
    <<Kind:8, B3/binary>> = B2,
    Rest = skip_import_desc(Kind, B3),
    parse_imports(Rest, N - 1, [{Mod, Field, kind_name(Kind)} | Acc]).

parse_export_section(Payload) ->
    {Count, Rest} = read_leb(Payload),
    parse_exports(Rest, Count, []).

parse_exports(_Bin, 0, Acc) -> lists:reverse(Acc);
parse_exports(Bin, N, Acc) ->
    {Name, B1} = read_name(Bin),
    <<Kind:8, B2/binary>> = B1,
    {_Idx, Rest} = read_leb(B2),
    parse_exports(Rest, N - 1, [{Name, kind_name(Kind)} | Acc]).

skip_import_desc(0, Bin) ->
    {_TypeIdx, Rest} = read_leb(Bin),
    Rest;
skip_import_desc(1, <<_ET:8, Bin/binary>>) ->
    {_Min, B1} = read_leb(Bin),
    case _ET band 1 of
        1 -> {_Max, B2} = read_leb(B1), B2;
        _ -> B1
    end;
skip_import_desc(2, <<Flags:8, Bin/binary>>) ->
    {_Min, B1} = read_leb(Bin),
    case Flags band 1 of
        1 -> {_Max, B2} = read_leb(B1), B2;
        _ -> B1
    end;
skip_import_desc(3, <<_T:8, _Mut:8, Rest/binary>>) ->
    Rest;
skip_import_desc(_, Bin) ->
    Bin.

kind_name(0) -> func;
kind_name(1) -> table;
kind_name(2) -> memory;
kind_name(3) -> global;
kind_name(K) -> K.

read_name(Bin) ->
    {Len, Rest} = read_leb(Bin),
    <<Name:Len/binary, Rest2/binary>> = Rest,
    {Name, Rest2}.

read_leb(Bin) ->
    read_leb(Bin, 0, 0).

read_leb(<<Byte:8, Rest/binary>>, Acc, Shift) ->
    Value = Acc bor ((Byte band 16#7F) bsl Shift),
    case Byte band 16#80 of
        0 -> {Value, Rest};
        _ -> read_leb(Rest, Value, Shift + 7)
    end.
