#!/bin/sh
set -eu

compiler=$1
test_bin_dir=$2
mkdir -p "$test_bin_dir"

for source in \
    tests/lexer/token_stream.dpp \
    tests/parser/operator_precedence.dpp \
    tests/semantic/function_calls.dpp \
    tests/ctfe/constant_folding.dpp \
    tests/codegen/control_flow.dpp \
    tests/compatibility/d_import_syntax.dpp \
    tests/compatibility/c_abi.dpp \
    tests/regression/compiler_pipeline.dpp
do
    name=$(basename "$source" .dpp)
    executable="$test_bin_dir/$name"
    "$compiler" -o "$executable" "$source"
    "$executable"
done

runtime_executable="$test_bin_dir/runtime-lifecycle"
"$compiler" -o "$runtime_executable" tests/runtime/runtime_lifecycle.dpp
"$runtime_executable"

clang -std=c11 -c tests/runtime/cleanup_probe.c -o "$test_bin_dir/cleanup_probe.o"
"$compiler" --link-object "$test_bin_dir/cleanup_probe.o" \
    -o "$test_bin_dir/scope-exit" tests/runtime/scope_exit.dpp
"$test_bin_dir/scope-exit"
"$compiler" --link-object "$test_bin_dir/cleanup_probe.o" \
    -o "$test_bin_dir/struct-lifetime" tests/runtime/struct_lifetime.dpp
"$test_bin_dir/struct-lifetime"
"$compiler" --link-object "$test_bin_dir/cleanup_probe.o" \
    -o "$test_bin_dir/struct-composition" tests/runtime/struct_composition.dpp
"$test_bin_dir/struct-composition"

exit_status_executable="$test_bin_dir/runtime-exit-status"
"$compiler" -o "$exit_status_executable" tests/runtime/exit_status.dpp
if "$exit_status_executable"; then
    echo "expected generated entry point to preserve the user main exit status" >&2
    exit 1
else
    exit_status=$?
    if [ "$exit_status" -ne 23 ]; then
        echo "expected exit status 23, received $exit_status" >&2
        exit 1
    fi
fi

ldc2 -c tests/compatibility/d_library.d -of"$test_bin_dir/d_library.o"
"$compiler" --link-object "$test_bin_dir/d_library.o" \
    -o "$test_bin_dir/d_library_interop" examples/d_library_interop.dpp
"$test_bin_dir/d_library_interop"

for source in examples/*.dpp
do
    name=$(basename "$source" .dpp)
    executable="$test_bin_dir/example-$name"
    if [ "$name" = d_library_interop ]; then
        "$compiler" --link-object "$test_bin_dir/d_library.o" -o "$executable" "$source"
    else
        "$compiler" -o "$executable" "$source"
    fi
    "$executable" >/dev/null
done

expect_error() {
    source=$1
    expected=$2
    log=$3
    if "$compiler" --check "$source" >"$log" 2>&1; then
        echo "expected $source to fail compilation" >&2
        exit 1
    fi
    grep -F "$expected" "$log" >/dev/null
}

expect_error tests/diagnostics/unknown_variable.dpp \
    "unknown variable 'missing'" "$test_bin_dir/unknown-variable.txt"
expect_error tests/diagnostics/type_mismatch.dpp \
    "cannot initialize int variable 'count' with bool" "$test_bin_dir/type-mismatch.txt"
expect_error tests/diagnostics/unsupported_import.dpp \
    "unsupported import 'std.file'" "$test_bin_dir/unsupported-import.txt"
expect_error tests/diagnostics/unsupported_scope_exit.dpp \
    "only scope(exit) cleanup is supported" "$test_bin_dir/unsupported-scope-exit.txt"
expect_error tests/diagnostics/break_outside_loop.dpp \
    "break statement is only valid inside a loop" "$test_bin_dir/break-outside-loop.txt"
expect_error tests/diagnostics/continue_outside_loop.dpp \
    "continue statement is only valid inside a loop" "$test_bin_dir/continue-outside-loop.txt"
expect_error tests/diagnostics/struct_unknown_field.dpp \
    "has no field named 'y'" "$test_bin_dir/struct-unknown-field.txt"
expect_error tests/diagnostics/struct_copy_rejected.dpp \
    "struct initialization requires a constructor call; copying is not supported" \
    "$test_bin_dir/struct-copy-rejected.txt"
expect_error tests/diagnostics/struct_no_constructor.dpp \
    "struct 'Point' has no default constructor" "$test_bin_dir/struct-no-constructor.txt"
expect_error tests/diagnostics/struct_parameter.dpp \
    "by-value struct parameters are not supported until copy semantics are implemented" \
    "$test_bin_dir/struct-parameter.txt"
expect_error tests/diagnostics/struct_return.dpp \
    "functions and methods cannot return structs in this compiler increment" \
    "$test_bin_dir/struct-return.txt"
expect_error tests/diagnostics/struct_no_matching_constructor.dpp \
    "no matching overload for 'Point'" "$test_bin_dir/struct-no-matching-ctor.txt"
expect_error tests/diagnostics/struct_array_index.dpp \
    "fixed-array index must be an in-range integer literal" \
    "$test_bin_dir/struct-array-index.txt"
expect_error tests/lexer/invalid_character.dpp \
    "unrecognized character '@'" "$test_bin_dir/lexer-error.txt"
expect_error tests/parser/missing_delimiter.dpp \
    "expected ')'" "$test_bin_dir/parser-error.txt"
expect_error tests/parser/integer_overflow.dpp \
    "integer literal is out of range" "$test_bin_dir/integer-overflow.txt"

"$compiler" --check --emit-ir "$test_bin_dir/pipeline.ll" tests/regression/compiler_pipeline.dpp
grep -F "define i32 @main()" "$test_bin_dir/pipeline.ll" >/dev/null
grep -F "call i32 @dpp_rt_initialize()" "$test_bin_dir/pipeline.ll" >/dev/null
"$compiler" --run -o "$test_bin_dir/run-mode" tests/lexer/token_stream.dpp \
    >"$test_bin_dir/run-mode.txt"
grep -F "lexer token stream" "$test_bin_dir/run-mode.txt" >/dev/null
"$compiler" run -o "$test_bin_dir/run-subcommand" tests/lexer/token_stream.dpp \
    >"$test_bin_dir/run-subcommand.txt"
grep -F "lexer token stream" "$test_bin_dir/run-subcommand.txt" >/dev/null

printf '%s\n' "D++ compiler integration tests passed."
