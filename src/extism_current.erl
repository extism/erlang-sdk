-module(extism_current).
%% Current-plugin helpers, used from host functions while a call is in flight.

-export([
    new/0,
    kernel/0,
    state/0,
    host_context/0,
    alloc/1,
    free/1,
    length/1,
    read/1,
    write/1,
    read_string/1,
    write_string/1
]).

-include("extism.hrl").

new() ->
    #{kernel => kernel(), host_context => host_context()}.

kernel() ->
    case get(extism_state) of
        #extism_state{kernel = K} -> K;
        _ -> error(no_current_plugin)
    end.

state() ->
    case get(extism_state) of
        #extism_state{} = S -> S;
        _ -> error(no_current_plugin)
    end.

host_context() ->
    case get(extism_state) of
        #extism_state{host_context = Ctx} -> Ctx;
        _ -> undefined
    end.

alloc(N) -> extism_kernel:alloc(kernel(), N).

free(Off) -> extism_kernel:free(kernel(), Off).

length(Off) -> extism_kernel:length(kernel(), Off).

read(Off) -> extism_kernel:read_block(kernel(), Off).

write(Bin) -> extism_kernel:write_block(kernel(), extism_util:to_bin(Bin)).

read_string(Off) ->
    case read(Off) of
        {ok, Bin} -> {ok, Bin};
        {error, _} = E -> E
    end.

write_string(S) -> write(S).
