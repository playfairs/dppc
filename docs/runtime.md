# D++ runtime

The runtime is a small C11 library with a stable C ABI. Keeping this low-level
boundary independent of the compiler's implementation language lets generated
LLVM code call it directly and lets native C programs test the ABI.

## Current implementation

`runtime/core/runtime.c` owns process lifecycle state. The generated native
`main` function calls `dpp_rt_initialize`, calls the source-level D++ `main`,
then calls `dpp_rt_finalize` while preserving the program's exit status.
Initialization is idempotent while running and safe for concurrent callers.
Initialization after finalization fails; the generated entry point reports that
failure through the runtime panic facility.
Finalization is intended to run after program threads have been joined; the
runtime does not yet manage thread shutdown or coordinate finalization with
concurrent allocations.

`runtime/memory/allocator.c` provides explicit aligned, zeroed, and
reallocating allocation plus deallocation. A zero alignment selects the
platform's fundamental alignment; other alignments must be powers of two.
Zero-size allocation requests return a unique one-byte allocation. Zeroed
allocation initializes that byte as well. Reallocation with a null pointer
allocates; a zero new size frees and returns null; alignment zero preserves the
old allocation's alignment. A failed nonzero reallocation leaves the original
block intact. Invalid alignments, requests that overflow size arithmetic, and
allocation failures return null.

Every live block is recorded in a lock-protected registry. This permits invalid
and repeated frees to be diagnosed without reading a header from an arbitrary
caller pointer, and makes allocation count/byte queries coherent snapshots.
The registry and counters are always enabled in this initial implementation, so
allocation is serialized and carries tracking overhead; debug-only tracking and
an untracked release allocator are future work. The runtime retains each
allocation's original pointer and deallocator, allowing an allocator to change
only while there are no live allocations. Custom allocator callbacks must return
storage aligned for `max_align_t`, must not re-enter the D++ runtime, and are
invoked while the allocator lock is held for allocation. Reallocation allocates
a replacement, copies the common prefix, then releases the original block.
Invalid and repeated frees are detected while an address is not currently
allocated; as with ordinary raw pointers, a stale pointer whose address has
since been reused cannot be distinguished from the new allocation.

`dpp_rt_set_allocator` installs paired allocation/deallocation hooks only when
the live-allocation registry is empty; passing null restores the system
allocator. Allocation-failure tests use these hooks to verify that failed
allocations and reallocations leave registry state and existing blocks intact.

`runtime/diagnostics/panic.c` prints a fatal diagnostic to standard error and
aborts. It is for unrecoverable runtime failures, not a substitute for
exceptions or recoverable error values.

The internal ABI is declared in `runtime/include/dpp/runtime.h`. Generated
programs link `libdpp_runtime.a`; the compiler locates it beside the compiler
build target or in the installed package's `lib` directory. Nox builds the
runtime library as a dependency, and the Nix package installs both the compiler
runtime archive, and C header. The current import system does not load this C
header, so a D++ source that directly uses runtime primitives declares their
`extern(C)` signatures explicitly. The runtime has no source-level memory
abstraction or ownership checker yet.

## Boundaries and current limitations

The compiler supports D-compatible `scope(exit)` statements for cleanup
expressions already supported by the language. This cleanup is compile-time
control-flow lowering, not a runtime registration stack: each lexical cleanup
is emitted in reverse registration order on normal fallthrough or return.
Nested blocks and loop-body iterations have separate cleanup scopes. Because
`break` and `continue` are supported, lowering emits cleanups for every scope
between the exit and the target loop edge.

Plain D++ structs can contain scalar/pointer fields and fields of previously
declared struct types. Fixed arrays of structs are supported as local variables
and struct fields, with lengths from 1 to 1024 and in-range integer-literal
indexing. The type/symbol model records field layout, constructor overloads,
user/generated destructor status, and whether a type needs destruction.

A struct may define overloaded constructors named after the struct, ordinary
instance methods, and a `~this()` destructor. Both constructors, methods, and
destructors receive an implicit reference named `this`. Struct storage is first
zero-initialized; then nested struct fields and fixed-array elements are
constructed in field/index declaration order; finally the selected outer
constructor runs. A type without an explicit constructor has an implicit
zero-argument construction path. If a type has constructors, default
construction requires an explicit zero-argument overload.

Destructor calls are registered in the existing lexical cleanup sequence, not
a separate runtime stack. Destructors run on fallthrough, `return`, `break`, and
`continue`, and interleave with `scope(exit)` in reverse registration order.
An explicit destructor body runs first; then its struct members are destroyed
in reverse field order, with fixed-array elements destroyed in reverse index
order. When a struct has destructible members but no user destructor, semantic
analysis synthesizes a destructor function whose body lowers actual member
destructor calls.

Construction is represented separately from zero initialization: lowering
tracks uninitialized storage, construction, and live values, and registers a
local's destructor only after its constructor has returned successfully.
Exceptions are not implemented, so partially constructed cleanup during
unwinding is not yet observable. Struct-by-value parameters and struct return
values are diagnosed; whole-struct copying and assignment remain rejected.
Fixed-array indexing is currently limited to in-range integer literals.
Move/copy operations, member-initializer lists, explicit destruction, and a
general ownership checker remain future work.

The allocator is a primitive, not the language's mandated ownership model.
There is no garbage collector, allocator interface, arena, ownership checker,
exception unwinder, thread runtime, or dynamic type metadata yet. Automatic
struct destruction is limited to the aggregate rules above. Panic is fatal and
does not unwind.
Generated `main` runs finalization on normal return; a panic aborts the process.
The runtime currently depends on C11 atomics and the host C library and has been
validated on the project's macOS development target. Other operating systems
and 32-bit data models are not yet certified.

As compiler features acquire runtime requirements, their ABI must be added here
and tested through generated programs. The compiler must not silently add
backend-specific runtime conventions.
