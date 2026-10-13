-module(extism_plugin).
-behaviour(gen_server).

-export([start_link/1, start_link/2, req/3, stop/1, cancel/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("extism.hrl").

start_link(Source) ->
    start_link(Source, #{}).

start_link(Source, Opts) ->
    case maps:take(name, Opts) of
        {Name, Rest} ->
            gen_server:start_link(Name, ?MODULE, {Source, Rest}, []);
        error ->
            gen_server:start_link(?MODULE, {Source, Opts}, [])
    end.

req(Pid, Request, Timeout) ->
    gen_server:call(Pid, Request, Timeout).

stop(Pid) ->
    gen_server:stop(Pid, normal, 5000).

cancel(Pid) ->
    gen_server:cast(Pid, cancel),
    ok.

init({Source, Opts}) ->
    process_flag(trap_exit, true),
    case extism_instance:open(Source, Opts) of
        {ok, Handle} -> {ok, #{handle => Handle}};
        {error, Reason} -> {stop, Reason}
    end.

handle_call({call, Func, Input, Opts}, _From, #{handle := H} = S) ->
    {reply, extism_instance:call(H, Func, Input, Opts), S};
handle_call({function_exists, Func}, _From, #{handle := H} = S) ->
    {reply, extism_instance:function_exists(H, Func), S};
handle_call({config, Config}, _From, #{handle := H} = S) ->
    {reply, extism_instance:config(H, Config), S};
handle_call(reset, _From, #{handle := H} = S) ->
    {reply, extism_instance:reset(H), S};
handle_call(last_error, _From, #{handle := H} = S) ->
    {reply, extism_instance:error(H), S};
handle_call(exports, _From, #{handle := H} = S) ->
    {reply, extism_instance:exports(H), S};
handle_call(allow_http_headers, _From, #{handle := H} = S) ->
    {reply, extism_instance:allow_http_response_headers(H), S};
handle_call(_Req, _From, S) ->
    {reply, {error, extism_error:new(host, unknown, <<"unknown request">>)}, S}.

handle_cast(cancel, S) ->
    {noreply, S};
handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, #{handle := H}) ->
    extism_instance:close(H),
    ok;
terminate(_Reason, _) ->
    ok.

code_change(_Old, State, _Extra) ->
    {ok, State}.
