(module
  (import "extism:host/env" "input_length" (func $input_length (result i64)))
  (import "extism:host/env" "input_load_u8" (func $input_load_u8 (param i64) (result i32)))
  (import "extism:host/env" "alloc" (func $alloc (param i64) (result i64)))
  (import "extism:host/env" "store_u8" (func $store_u8 (param i64 i32)))
  (import "extism:host/env" "output_set" (func $output_set (param i64 i64)))
  (func (export "echo")
    (local $i i64)
    (local $n i64)
    (local $out i64)
    (local.set $n (call $input_length))
    (local.set $out (call $alloc (local.get $n)))
    (block $done
      (loop $copy
        (br_if $done (i64.ge_u (local.get $i) (local.get $n)))
        (call $store_u8
          (i64.add (local.get $out) (local.get $i))
          (call $input_load_u8 (local.get $i)))
        (local.set $i (i64.add (local.get $i) (i64.const 1)))
        (br $copy)))
    (call $output_set (local.get $out) (local.get $n))))
