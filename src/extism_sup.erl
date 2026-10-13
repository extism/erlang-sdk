-module(extism_sup).
-behaviour(supervisor).

-export([start_link/0, start_plugin/1, start_plugin/2]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_plugin(Source) ->
    start_plugin(Source, #{}).

start_plugin(Source, Opts) ->
    supervisor:start_child(?MODULE, [Source, Opts]).

init([]) ->
    Flags = #{strategy => simple_one_for_one, intensity => 10, period => 10},
    Child = #{
        id => extism_plugin,
        start => {extism_plugin, start_link, []},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [extism_plugin]
    },
    {ok, {Flags, [Child]}}.
