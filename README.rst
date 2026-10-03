D++
====

D++ is a systems programming language derived from D. Its longterm goal
is a compatible D foundation plus a first class D++ extension layer; the current
compiler implements an intentionally small, executable language subset.

The ``dpp`` compiler parses ``.dpp`` source, checks the supported core, lowers it
to LLVM IR, and invokes Clang to produce a native executable.
Generated executables link the foundational C ABI runtime in ``runtime/``.
The runtime ABI and its current implementation boundary are documented in
``docs/runtime.md``.

Goals
-----

- Preserve D compatibility as the baseline language model.
- Extend D with explicit D++ semantics and tooling.
- Provide a clean, stage-based compiler pipeline.
- Support future native code generation, optimization, and runtime work.
- Keep the project reproducible via Nix and CI-friendly tooling.

Development environment
-----------------------

The project is designed to be reproducible with Nix:

.. code-block:: bash

   nix develop

The development shell provides the Nox build system and D compiler toolchain.
Nox uses ``nox.build`` to declare compiler targets and ``noxfile`` for automation
tasks. On platforms where DMD is unavailable from nixpkgs, the shell uses LDC.

Build commands
--------------

.. code-block:: bash

   nix develop
   nox setup build
   nox compile -C build
   nox test

``nox setup`` configures the declared D executable target; ``nox compile`` builds
it. ``nox test`` runs the project's Nox task, which builds the compiler and checks
the compiler, compiles and runs the examples and integration programs, and
asserts useful diagnostics for invalid programs.

Compile an example after building the compiler with::

   ./build/debug/dpp/dpp examples/hello_world.dpp -o build/hello_world
   ./build/hello_world

Compile and immediately run a source file with::

   ./build/debug/dpp/dpp run examples/hello_world.dpp

Current compiler boundary
-------------------------

The implemented core includes primitive types, functions, local variables,
expressions, conditionals, loops, C ABI declarations/calls, the limited
``std.stdio : writeln`` intrinsic, and D-compatible ``scope(exit)`` cleanup
expressions. ``scope(exit)`` actions run in reverse registration order on
fallthrough, return, ``break``, and ``continue``. Automatic destruction of
user-defined values, constructors, ownership analysis, and exception cleanup
are not implemented.
