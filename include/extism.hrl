-ifndef(EXTISM_HRL).
-define(EXTISM_HRL, true).

-define(EXTISM_ENV, <<"extism:host/env">>).
-define(EXTISM_USER, <<"extism:host/user">>).
-define(EXTISM_LEGACY_ENV, <<"env">>).
-define(EXTISM_WASI, <<"wasi_snapshot_preview1">>).

-define(KERNEL_FUNS, [
    <<"alloc">>,
    <<"free">>,
    <<"length">>,
    <<"length_unsafe">>,
    <<"load_u8">>,
    <<"load_u64">>,
    <<"store_u8">>,
    <<"store_u64">>,
    <<"input_load_u8">>,
    <<"input_load_u64">>,
    <<"input_set">>,
    <<"output_set">>,
    <<"input_length">>,
    <<"input_offset">>,
    <<"output_length">>,
    <<"output_offset">>,
    <<"reset">>,
    <<"error_set">>,
    <<"error_get">>,
    <<"memory_bytes">>
]).

-define(HIDDEN_EXPORTS, [
    <<"memory">>,
    <<"_start">>,
    <<"_initialize">>,
    <<"__wasm_call_ctors">>,
    <<"__data_end">>,
    <<"__heap_base">>,
    <<"__indirect_function_table">>,
    <<"__wasm_apply_data_relocs">>,
    <<"hs_init">>,
    <<"__main_void">>,
    <<"cabi_realloc">>
]).

-record(extism_function, {
    name :: binary(),
    namespace :: binary(),
    params :: [atom()],
    results :: [atom()],
    callback :: function(),
    user_data :: term()
}).

-record(extism_state, {
    kernel_mod,
    kernel,
    plugin_mod,
    plugin,
    source_hash :: binary(),
    config = #{} :: #{binary() => binary()},
    vars = #{} :: #{binary() => binary()},
    functions = #{} :: term(),
    wasi = false :: boolean() | map(),
    allowed_hosts = undefined :: undefined | allow_all | [binary()],
    allowed_paths = #{} :: #{binary() => binary()},
    max_http_response_bytes = 52428800 :: non_neg_integer(),
    max_var_bytes = 1048576 :: non_neg_integer(),
    allow_http_headers = false :: boolean(),
    last_http_status = 0 :: integer(),
    last_http_headers = #{} :: #{binary() => binary()},
    last_error = undefined :: undefined | binary(),
    log_level = info :: atom(),
    fuel :: undefined | non_neg_integer(),
    max_depth :: undefined | pos_integer(),
    timeout_ms = 30000 :: timeout(),
    exports = [] :: [binary()],
    host_context :: term()
}).

-endif.
