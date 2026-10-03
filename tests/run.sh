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
expect_error tests/lexer/invalid_character.dpp \
    "unrecognized character '@'" "$test_bin_dir/lexer-error.txt"
expect_error tests/parser/missing_delimiter.dpp \
    "expected ')'" "$test_bin_dir/parser-error.txt"
expect_error tests/parser/integer_overflow.dpp \
    "integer literal is out of range" "$test_bin_dir/integer-overflow.txt"

"$compiler" --check --emit-ir "$test_bin_dir/pipeline.ll" tests/regression/compiler_pipeline.dpp
grep -F "define i32 @main()" "$test_bin_dir/pipeline.ll" >/dev/null
"$compiler" --run -o "$test_bin_dir/run-mode" tests/lexer/token_stream.dpp \
    >"$test_bin_dir/run-mode.txt"
grep -F "lexer token stream" "$test_bin_dir/run-mode.txt" >/dev/null
"$compiler" run -o "$test_bin_dir/run-subcommand" tests/lexer/token_stream.dpp \
    >"$test_bin_dir/run-subcommand.txt"
grep -F "lexer token stream" "$test_bin_dir/run-subcommand.txt" >/dev/null

printf '%s\n' "D++ compiler integration tests passed."
