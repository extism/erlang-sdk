-module(extism_kernel).
%% Official Extism kernel (extism-runtime.wasm) plus helpers to move
%% bytes through its bump allocator.

-export([
    load/0,
    instantiate/1,
    env_externs/1,
    reset/1,
    alloc/2,
    free/2,
    length/2,
    write_block/2,
    read_block/2,
    read_bytes/3,
    write_bytes/3,
    input_set/2,
    output/1,
    error/1,
    error_set/2,
    call/3
]).

-include("extism.hrl").

load() ->
    Path = extism_util:kernel_path(),
    case wasm:load_file(Path) of
        {ok, Mod} -> {ok, Mod};
        {error, Reason} -> {error, {kernel_load_failed, Path, Reason}}
    end.

instantiate(Mod) ->
    case wasm:instantiate(Mod, #{}) of
        {ok, Inst} ->
            _ = reset(Inst),
            {ok, Inst};
        {error, Reason} ->
            {error, {kernel_instantiate_failed, Reason}}
    end.

env_externs(Kernel) ->
    lists:foldl(
        fun(Name, Acc) ->
            case wasm:extern(Kernel, Name) of
                {ok, Ext} ->
                    Acc#{{?EXTISM_ENV, Name} => Ext};
                {error, _} ->
                    Acc
            end
        end,
        #{},
        ?KERNEL_FUNS
    ).

reset(Kernel) ->
    case call(Kernel, <<"reset">>, []) of
        {ok, _} -> ok;
        {error, _} = E -> E
    end.

alloc(_Kernel, 0) -> {ok, 0};
alloc(Kernel, N) ->
    case call(Kernel, <<"alloc">>, [N]) of
        {ok, [Off]} -> {ok, Off};
        {ok, []} -> {error, alloc_no_result};
        {error, _} = E -> E
    end.

free(_Kernel, 0) -> ok;
free(Kernel, Off) ->
    case call(Kernel, <<"free">>, [Off]) of
        {ok, _} -> ok;
        {error, _} = E -> E
    end.

length(Kernel, Off) ->
    case call(Kernel, <<"length">>, [Off]) of
        {ok, [Len]} -> {ok, Len};
        {error, _} = E -> E
    end.

write_block(_Kernel, <<>>) -> {ok, 0};
write_block(Kernel, Bin) when is_binary(Bin) ->
    Size = byte_size(Bin),
    case alloc(Kernel, Size) of
        {ok, 0} ->
            {error, {alloc_failed, Size}};
        {ok, Off} ->
            case wasm:write_memory(Kernel, Off, Bin) of
                ok -> {ok, Off};
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end.

read_block(_Kernel, 0) -> {ok, <<>>};
read_block(Kernel, Off) ->
    case length(Kernel, Off) of
        {ok, 0} -> {ok, <<>>};
        {ok, Len} -> read_bytes(Kernel, Off, Len);
        {error, _} = E -> E
    end.

read_bytes(_Kernel, _Off, 0) -> {ok, <<>>};
read_bytes(Kernel, Off, Len) ->
    wasm:read_memory(Kernel, Off, Len).

write_bytes(Kernel, Off, Bin) ->
    wasm:write_memory(Kernel, Off, Bin).

input_set(Kernel, Input) when is_binary(Input) ->
    Size = byte_size(Input),
    case Size of
        0 ->
            call(Kernel, <<"input_set">>, [0, 0]);
        _ ->
            case write_block(Kernel, Input) of
                {ok, Off} -> call(Kernel, <<"input_set">>, [Off, Size]);
                {error, _} = E -> E
            end
    end.

output(Kernel) ->
    case call(Kernel, <<"output_offset">>, []) of
        {ok, [0]} ->
            {ok, <<>>};
        {ok, [Off]} ->
            case call(Kernel, <<"output_length">>, []) of
                {ok, [0]} -> {ok, <<>>};
                {ok, [Len]} -> read_bytes(Kernel, Off, Len);
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end.

error(Kernel) ->
    case call(Kernel, <<"error_get">>, []) of
        {ok, [0]} -> undefined;
        {ok, [Off]} ->
            case read_block(Kernel, Off) of
                {ok, Bin} -> Bin;
                {error, _} -> undefined
            end;
        {error, _} ->
            undefined
    end.

error_set(Kernel, Msg) ->
    case write_block(Kernel, extism_util:to_bin(Msg)) of
        {ok, Off} -> call(Kernel, <<"error_set">>, [Off]);
        {error, _} = E -> E
    end.

call(Kernel, Name, Args) ->
    wasm:call(Kernel, Name, Args).
