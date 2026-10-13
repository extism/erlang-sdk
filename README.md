# Extism Erlang SDK

A **native** Extism host SDK for Erlang/OTP. Plugins run on
[erlang_wasm](https://github.com/benoitc/erlang_wasm). This library implements
the Extism kernel, host env, manifests, host functions and WASI on that engine.

Requires **OTP 29+**.

## Use it

The default handle lives in **your process**. No gen_server, no mailbox hop.

```erlang
{ok, P} = extism:open("priv/plugins/count_vowels.wasm"),
{ok, Out} = extism:call(P, count_vowels, <<"Hello, World!">>),
ok = extism:close(P).
%% Out = <<"{\"count\":3,\"total\":3,\"vowels\":\"aeiouAEIOU\"}">>
```

`new/1` is the same as `open/1`. A path, raw bytes, WAT, a bundled name, or a
[manifest](https://extism.org/docs/concepts/manifest) are all fine:

```erlang
{ok, P} = extism:open(#{
    wasm => [#{path => "plugin.wasm"}],
    config => #{<<"vowels">> => <<"aeiou">>},
    allowed_hosts => [<<"example.com">>]
}).
```

## Host functions

A map of funs. Arity is the number of Extism memory handles; values are
binaries. That is the usual PDK shape (`String` / `Vec<u8>`).

```erlang
{ok, P} = extism:open(count_vowels_kvstore, #{
    functions => #{
        kv_read => fun(Key) -> {ok, maps:get(Key, Store, <<0,0,0,0>>)} end,
        kv_write => fun(Key, Val) -> ets:insert(T, {Key, Val}), ok end
    }
}).
```

When you need the handle (or raw `i64` offsets):

```erlang
#{host_reflect => {raw, [i64], [i64], fun(P, [Off]) ->
    {ok, In} = extism:read(P, Off),
    extism:write(P, In)
end}}
```

## OTP

Own the instance from a worker when you want a name, a supervisor, or to kill
a runaway call by stopping the process.

```erlang
{ok, Pid} = extism:start_link(Source, #{name => {local, vowels}}),
{ok, Out} = extism:call(Pid, count_vowels, <<"hi">>),

%% in your supervisor:
extism:child_spec(Source, Opts, #{id => vowels}).
```

`call/3` accepts either the inline handle or the pid.

## Errors

Every failure is one map:

```erlang
{error, #{class := plugin | link | trap | host | timeout | manifest,
          reason := atom(),
          message := binary()}}
```

## Bundled plugins

`priv/plugins/` has real guests from Extism PDK and SDK repos. See
`priv/plugins/SOURCES.md`.

```erlang
extism:bundled_plugins().
```

## Develop

```sh
rebar3 compile
rebar3 ct
rebar3 shell
```
