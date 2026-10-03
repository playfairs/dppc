D++ examples
============

Every ``.dpp`` file in this directory is compiled and run by ``nox test``.
The current compiler increment deliberately uses a small, working language
subset; these examples do not claim support for syntax the compiler cannot
parse.

Examples
--------

``binary_frame.dpp``
   Validates a payload length and computes the byte size of a framed message
   using checked control flow and functions. Raw layout and byte buffers are not
   implemented yet.
``c_library_interop.dpp``
   Calls C's ``puts`` through an ``extern(C)`` declaration.
``d_library_interop.dpp``
   Links a function implemented in D with LDC against a D++ caller using an
   explicit ``extern(C)`` boundary. This tests C ABI interoperability with a D
   object, not D's native mangled ABI.
``generic_compile_time.dpp``
   Uses constant integer expressions that the compiler folds before native
   code generation. The file remains a small arithmetic example; templates,
   generic constraints, CTFE function execution, and reflection are not
   implemented yet.
``hello_world.dpp``
   The minimal module, import, entry point, and output example.
``owned_output.dpp``
   Opens, writes, and closes a file through C stdio. The program handles the
   resource explicitly; D++ ownership types, automatic drop, and unwinding
   cleanup are not implemented yet.
``parallel_checksum.dpp``
   Computes a checksum over a bounded range with a loop. It is intentionally
   sequential because concurrency and atomics are not implemented yet.
``service_log_report.dpp``
   Aggregates service counters and returns a status for malformed records.
   File parsing and associative containers are not implemented yet.
``shipping_estimate.dpp``
   Calculates shipping and a final amount using typed variables, functions,
   comparisons, and control flow.
``shopping_cart.dpp``
   Computes line-item and cart totals through reusable functions. User-defined
   structs, classes, and operator overloads are not implemented yet.

Build and run
-------------

Compile and run every example, plus lexer/parser/semantic/codegen/diagnostics
regressions, with::

   nix develop -c nox test

Compile a standalone example with::

   nix develop -c ./build/debug/dpp/dpp examples/hello_world.dpp -o build/hello_world
   ./build/hello_world

Compile and immediately run one example with::

   nix develop -c ./build/debug/dpp/dpp run examples/hello_world.dpp

The D library ABI example is linked to the small D fixture under
``tests/compatibility`` by the Nox integration test.
