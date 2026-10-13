-module(extism_http).

-export([request/3]).

%% Perform an Extism plugin HTTP request. RequestJSON is the Extism PDK
%% HttpRequest object: #{<<"url">> := Url, <<"method">> => Method, <<"headers">> => #{}}.
request(RequestJSON, Body, Opts) ->
    case decode_request(RequestJSON) of
        {error, _} = E ->
            E;
        {ok, #{url := Url} = Req} ->
            Host = host_of(Url),
            Allowed = maps:get(allowed_hosts, Opts, undefined),
            case extism_util:host_allowed(Host, Allowed) of
                false ->
                    {error, {http_not_allowed, Url}};
                true ->
                    do_request(Req, Body, Opts)
            end
    end.

decode_request(Bin) when is_binary(Bin) ->
    case thoas:decode(Bin) of
        {ok, Map} when is_map(Map) -> {ok, norm_req(Map)};
        {error, Reason} -> {error, {invalid_http_request, Reason}}
    end;
decode_request(Map) when is_map(Map) ->
    {ok, norm_req(Map)}.

norm_req(Map) ->
    Url = maps:get(<<"url">>, Map, maps:get(url, Map, <<>>)),
    Method0 = maps:get(<<"method">>, Map, maps:get(method, Map, <<"GET">>)),
    Method = string:uppercase(extism_util:to_bin(Method0)),
    Headers0 = maps:get(
        <<"headers">>,
        Map,
        maps:get(headers, Map, maps:get(<<"header">>, Map, maps:get(header, Map, #{})))
    ),
    Headers = case Headers0 of
        H when is_map(H) ->
            [{extism_util:to_bin(K), extism_util:to_bin(V)} || {K, V} <- maps:to_list(H)];
        _ ->
            []
    end,
    #{url => extism_util:to_bin(Url), method => Method, headers => Headers}.

host_of(Url) ->
    case uri_string:parse(Url) of
        #{host := Host} when Host =/= undefined, Host =/= <<>> ->
            extism_util:to_bin(Host);
        _ ->
            <<>>
    end.

do_request(#{url := Url, method := Method, headers := Headers}, Body, Opts) ->
    Timeout = maps:get(timeout, Opts, 30000),
    Max = maps:get(max_http_response_bytes, Opts, 50 * 1024 * 1024),
    HTTPOpts = [{timeout, Timeout}, {connect_timeout, Timeout}],
    UrlStr = binary_to_list(Url),
    Hdrs = [{binary_to_list(K), binary_to_list(V)} || {K, V} <- Headers],
    MethodAtom = method_atom(Method),
    Request = case {MethodAtom, Body} of
        {get, _} -> {UrlStr, Hdrs};
        {head, _} -> {UrlStr, Hdrs};
        {delete, _} -> {UrlStr, Hdrs};
        {_, undefined} -> {UrlStr, Hdrs, "application/octet-stream", <<>>};
        {_, <<>>} -> {UrlStr, Hdrs, content_type(Headers), <<>>};
        {_, B} -> {UrlStr, Hdrs, content_type(Headers), B}
    end,
    case httpc:request(MethodAtom, Request, HTTPOpts, [{body_format, binary}]) of
        {ok, {{_Vsn, Status, _Reason}, RespHeaders, RespBody0}} ->
            RespBody = truncate(RespBody0, Max),
            HeaderMap = headers_to_map(RespHeaders),
            {ok, Status, HeaderMap, RespBody};
        {ok, {Status, RespBody0}} when is_integer(Status) ->
            {ok, Status, #{}, truncate(RespBody0, Max)};
        {error, Reason} ->
            {error, {http_error, Reason}}
    end.

method_atom(<<"GET">>) -> get;
method_atom(<<"POST">>) -> post;
method_atom(<<"PUT">>) -> put;
method_atom(<<"DELETE">>) -> delete;
method_atom(<<"HEAD">>) -> head;
method_atom(<<"PATCH">>) -> patch;
method_atom(<<"OPTIONS">>) -> options;
method_atom(Other) ->
    try binary_to_existing_atom(string:lowercase(Other), utf8) of
        Atom -> Atom
    catch
        _:_ -> get
    end.

content_type(Headers) ->
    case lists:keyfind(<<"content-type">>, 1, [{string:lowercase(K), V} || {K, V} <- Headers]) of
        {_, CT} -> binary_to_list(CT);
        false -> "application/octet-stream"
    end.

headers_to_map(Headers) ->
    maps:from_list([
        {string:lowercase(extism_util:to_bin(K)), header_val(V)}
        || {K, V} <- Headers
    ]).

header_val(V) when is_list(V) ->
    case io_lib:printable_list(V) of
        true -> list_to_binary(V);
        false -> iolist_to_binary(lists:join(<<",">>, [extism_util:to_bin(X) || X <- V]))
    end;
header_val(V) ->
    extism_util:to_bin(V).

truncate(Bin, Max) when is_binary(Bin), byte_size(Bin) > Max ->
    binary:part(Bin, 0, Max);
truncate(Bin, _) when is_binary(Bin) ->
    Bin;
truncate(List, Max) when is_list(List) ->
    truncate(iolist_to_binary(List), Max);
truncate(Other, _) ->
    extism_util:to_bin(Other).
