-module(extism).
-moduledoc """
Native Extism Host SDK for Erlang.

Plugins run on [erlang_wasm](https://github.com/benoitc/erlang_wasm). This
library implements the Extism kernel, `extism:host/env`, manifests, host
functions and WASI on that engine.

The default handle is **inline**: owned by the calling process, no gen_server.

```erlang
{ok, P} = extism:open(#{wasm => [#{path => "count_vowels.wasm"}]}),
{ok, Out} = extism:call(P, count_vowels, <<"Hello, World!">>),
ok = extism:close(P).
```

Put a process in front when you want a name, a supervisor, or a mailbox:

```erlang
{ok, Pid} = extism:start_link(Source, #{name => {local, vowels}}),
extism:child_spec(Source, Opts, #{id => vowels}).
```
""".

-export([
    version/0,
    kernel_version/0,
    open/1, open/2,
    new/1, new/2,
    start_link/1, start_link/2,
    child_spec/1, child_spec/2, child_spec/3,
    call/3, call/4,
    function_exists/2,
    config/2,
    reset/1,
    error/1,
    exports/1,
    close/1,
    stop/1,
    free/1,
    cancel/1,
    allow_http_response_headers/1,
    read/2,
    write/2,
    host_context/1,
    plugin_path/1,
    bundled_plugins/0
]).

-export_type([plugin/0, source/0, options/0, error/0]).

-type plugin() :: pid() | #{extism := plugin, ref := reference()}.
-type source() ::
    binary()
    | string()
    | atom()
    | map()
    | {wat, binary()}
    | {url, binary() | string()}
    | {plugin, binary() | string() | atom()}.
-type options() :: map().
-type error() :: extism_error:error().

version() -> <<"0.1.0">>.

kernel_version() ->
    Path = filename:flatten([extism_util:kernel_path(), ".version"]),
    case file:read_file(Path) of
        {ok, Vsn} -> string:trim(Vsn);
        {error, _} -> <<"unknown">>
    end.

%% @doc Load a plugin in this process. The handle is only valid here.
-spec open(source()) -> {ok, plugin()} | {error, error()}.
open(Source) ->
    open(Source, #{}).

-spec open(source(), options()) -> {ok, plugin()} | {error, error()}.
open(Source, Opts) ->
    {ok, _} = application:ensure_all_started(extism),
    extism_instance:open(Source, Opts).

%% @doc Same as `open/1`. Kept for Extism familiarity.
new(Source) -> open(Source).
new(Source, Opts) -> open(Source, Opts).

%% @doc Run the plugin in a worker. Use this under a supervisor.
-spec start_link(source()) -> {ok, pid()} | {error, term()}.
start_link(Source) ->
    start_link(Source, #{}).

-spec start_link(source(), options()) -> {ok, pid()} | {error, term()}.
start_link(Source, Opts) ->
    {ok, _} = application:ensure_all_started(extism),
    extism_plugin:start_link(Source, Opts).

-spec child_spec(source()) -> supervisor:child_spec().
child_spec(Source) ->
    child_spec(Source, #{}, #{}).

-spec child_spec(source(), options()) -> supervisor:child_spec().
child_spec(Source, Opts) ->
    child_spec(Source, Opts, #{}).

-spec child_spec(source(), options(), map()) -> supervisor:child_spec().
child_spec(Source, Opts, Spec) ->
    #{
        id => maps:get(id, Spec, extism_plugin),
        start => {extism, start_link, [Source, Opts]},
        restart => maps:get(restart, Spec, permanent),
        shutdown => maps:get(shutdown, Spec, 5000),
        type => worker,
        modules => [extism_plugin]
    }.

-spec call(plugin(), binary() | string() | atom(), iodata()) ->
    {ok, binary()} | {error, error()}.
call(Plugin, Func, Input) ->
    call(Plugin, Func, Input, #{}).

-spec call(plugin(), binary() | string() | atom(), iodata(), map()) ->
    {ok, binary()} | {error, error()}.
call(Plugin, Func, Input, Opts) ->
    dispatch(Plugin, fun(H) ->
        extism_instance:call(H, extism_util:to_bin(Func), to_bin(Input), Opts)
    end, {call, extism_util:to_bin(Func), to_bin(Input), Opts},
        maps:get(timeout, Opts, default_timeout(Plugin))).

-spec function_exists(plugin(), binary() | string() | atom()) -> boolean().
function_exists(Plugin, Func) ->
    case dispatch(Plugin, fun(H) ->
        {ok, extism_instance:function_exists(H, Func)}
    end, {function_exists, extism_util:to_bin(Func)}) of
        {ok, Bool} -> Bool;
        Bool when is_boolean(Bool) -> Bool;
        {error, _} -> false
    end.

-spec config(plugin(), map() | list()) -> ok | {error, error()}.
config(Plugin, Config) ->
    dispatch(Plugin, fun(H) -> extism_instance:config(H, Config) end, {config, Config}).

-spec reset(plugin()) -> ok | {error, error()}.
reset(Plugin) ->
    dispatch(Plugin, fun(H) -> extism_instance:reset(H) end, reset).

-spec error(plugin()) -> undefined | binary().
error(Plugin) ->
    case dispatch(Plugin, fun(H) -> {ok, extism_instance:error(H)} end, last_error) of
        {ok, Err} -> Err;
        {error, _} -> undefined;
        Err -> Err
    end.

-spec exports(plugin()) -> [binary()].
exports(Plugin) ->
    case dispatch(Plugin, fun(H) -> {ok, extism_instance:exports(H)} end, exports) of
        {ok, Es} -> Es;
        Es when is_list(Es) -> Es;
        {error, _} -> []
    end.

%% @doc Release an inline handle, or stop a worker.
-spec close(plugin()) -> ok.
close(Plugin) when is_pid(Plugin) ->
    stop(Plugin);
close(Plugin) ->
    extism_instance:close(Plugin).

-spec stop(pid()) -> ok.
stop(Pid) when is_pid(Pid) ->
    extism_plugin:stop(Pid).

%% @doc Same as `close/1`.
free(Plugin) ->
    close(Plugin).

cancel(Plugin) when is_pid(Plugin) ->
    extism_plugin:cancel(Plugin);
cancel(_Plugin) ->
    ok.

allow_http_response_headers(Plugin) ->
    dispatch(Plugin, fun extism_instance:allow_http_response_headers/1, allow_http_headers).

%% @doc Read an Extism memory handle. For use from host functions.
-spec read(plugin(), integer()) -> {ok, binary()} | {error, term()}.
read(Plugin, Off) ->
    extism_instance:read(Plugin, Off).

-spec write(plugin(), iodata()) -> {ok, integer()} | {error, term()}.
write(Plugin, Bin) ->
    extism_instance:write(Plugin, Bin).

-spec host_context(plugin()) -> term().
host_context(Plugin) ->
    extism_instance:host_context(Plugin).

-spec plugin_path(binary() | string() | atom()) -> file:filename_all().
plugin_path(Name) ->
    extism_util:plugin_path(Name).

-spec bundled_plugins() -> [binary()].
bundled_plugins() ->
    Dir = extism_util:plugin_dir(),
    case file:list_dir(Dir) of
        {ok, Files} ->
            [extism_util:to_bin(filename:rootname(F))
             || F <- lists:sort(Files), filename:extension(F) =:= ".wasm"];
        {error, _} ->
            []
    end.

dispatch(Pid, _Inline, Request) when is_pid(Pid) ->
    extism_plugin:req(Pid, Request, 30000);
dispatch(Handle, Inline, _Request) ->
    Inline(Handle).

dispatch(Pid, _Inline, Request, Timeout) when is_pid(Pid) ->
    extism_plugin:req(Pid, Request, Timeout);
dispatch(Handle, Inline, _Request, _Timeout) ->
    Inline(Handle).

default_timeout(Pid) when is_pid(Pid) -> 30000;
default_timeout(_) -> infinity.

to_bin(B) when is_binary(B) -> B;
to_bin(Other) -> extism_util:to_bin(Other).
