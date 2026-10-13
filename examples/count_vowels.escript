#!/usr/bin/env escript
%% -*- erlang -*-
-module(count_vowels).

main(Args) ->
    code:add_pathsa(filelib:wildcard("_build/default/lib/*/ebin")),
    Input = case Args of
        [S | _] -> list_to_binary(S);
        [] -> <<"Hello, World!">>
    end,
    {ok, _} = application:ensure_all_started(extism),
    {ok, Plugin} = extism:open(count_vowels),
    {ok, Out} = extism:call(Plugin, count_vowels, Input),
    io:format("~s~n", [Out]),
    extism:close(Plugin).
