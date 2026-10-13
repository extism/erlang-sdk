# Bundled plugins

These `.wasm` files were downloaded from official Extism PDK and SDK
repositories so the Erlang host SDK can be exercised against real guest
modules, not fixtures invented for this tree.

| File | Source |
| --- | --- |
| `count_vowels.wasm` | [extism/plugins v1.1.1](https://github.com/extism/plugins/releases/tag/v1.1.1) (Rust PDK) |
| `count_vowels_kvstore.wasm` | extism/plugins v1.1.1 (Rust PDK + `extism:host/user` kv host fns) |
| `greet.wasm` | extism/plugins v1.1.1 (Rust PDK) |
| `echo.wasm` | extism/plugins v1.1.1 |
| `consume.wasm` | extism/plugins v1.1.1 |
| `upper.wasm` | extism/plugins v1.1.1 |
| `reflect.wasm` | extism/plugins v1.1.1 (calls `host_reflect`) |
| `input_offset.wasm` | extism/plugins v1.1.1 |
| `read_write.wasm` | extism/plugins v1.1.1 (WASI filesystem) |
| `http.wasm` | extism/plugins v1.1.1 (`extism:host/env` HTTP) |
| `go_alloc.wasm` | [extism/go-sdk](https://github.com/extism/go-sdk/tree/main/wasm) |
| `python_code-functions.wasm` | [extism/python-sdk](https://github.com/extism/python-sdk/tree/main/wasm) |

The Extism kernel is `priv/extism-runtime.wasm`, taken from
[extism/go-sdk](https://github.com/extism/go-sdk) (`v1.7.0`), which is the
same kernel built from [extism/extism/kernel](https://github.com/extism/extism/tree/main/kernel).
