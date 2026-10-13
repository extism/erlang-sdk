-module(extism_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(ssl),
    extism_sup:start_link().

stop(_State) ->
    ok.
