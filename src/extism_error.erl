-module(extism_error).

-export([new/3, new/4, wrap/2, wrap/3]).

-export_type([error/0, class/0]).

-type class() :: manifest | link | plugin | trap | host | timeout.
-type error() :: #{
    class := class(),
    reason := atom() | term(),
    message := binary(),
    cause => term()
}.

new(Class, Reason, Message) ->
    #{class => Class, reason => Reason, message => extism_util:to_bin(Message)}.

new(Class, Reason, Message, Cause) ->
    (new(Class, Reason, Message))#{cause => Cause}.

wrap(Class, #{class := _, reason := Reason, msg := Msg} = Cause) ->
    {error, new(Class, Reason, Msg, Cause)};
wrap(Class, #{class := _, kind := Reason, msg := Msg} = Cause) ->
    {error, new(Class, Reason, Msg, Cause)};
wrap(Class, #{message := Msg} = Cause) ->
    {error, new(Class, maps:get(reason, Cause, error), Msg, Cause)};
wrap(Class, {Reason, Detail}) when is_atom(Reason) ->
    {error, new(Class, Reason, format(Detail), {Reason, Detail})};
wrap(Class, Reason) when is_atom(Reason) ->
    {error, new(Class, Reason, atom_to_binary(Reason, utf8))};
wrap(Class, Reason) ->
    {error, new(Class, error, format(Reason), Reason)}.

wrap(Class, Reason, Detail) ->
    {error, new(Class, Reason, format(Detail), Detail)}.

format(Bin) when is_binary(Bin) -> Bin;
format(#{msg := M}) -> extism_util:to_bin(M);
format(#{message := M}) -> extism_util:to_bin(M);
format(Other) -> extism_util:to_bin(io_lib:format("~p", [Other])).
