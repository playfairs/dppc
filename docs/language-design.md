# D++ language design

## Design goal

D++ is D with a compatible extension layer, not C++ syntax translated through a
D-shaped frontend. Existing D semantics are the default foundation. New
semantics are added only when they solve a problem not already handled well by
D, and they are represented directly in the compiler's type and semantic model.

The intended file convention is:

* `.d` is D compatibility mode.
* `.dpp` is D++ mode: D-compatible declarations plus explicitly specified D++
  extensions.

D++ source is compiled from tokens and syntax trees to typed IR and native code.
It is not rewritten into D source.

## Preserve D's model

D++ keeps D's module/import organization, static and dynamic arrays, slices,
associative arrays, structs, classes, interfaces, delegates, ranges, contracts,
attributes, templates, aliases, enums, CTFE and compile-time introspection.
The existing `const`, `immutable`, `shared`, `scope`, `@safe`, `@trusted`,
`@system`, exception and GC models remain meaningful. The compiler should
improve implementation quality, diagnostics, optimization and interoperability
without needlessly replacing these facilities.

Class inheritance remains single inheritance plus multiple interface
implementation. That gives D++ polymorphism and virtual dispatch while avoiding
multiple implementation-base layout ambiguity. Templates and constraints remain
the generic programming system; D++ should improve their behavior rather than
introducing C++-inspired duplicate syntax.

## D++ ownership extension

The initial D++-specific extension is opt-in deterministic ownership, complementing
D's GC and existing scoped cleanup facilities.

```d
struct PacketBuffer {
    ubyte[] bytes;

    this(size_t capacity) {
        bytes = new ubyte[capacity];
    }

    ~this() {
        // Release any non-GC/native resource owned by this value.
    }
}

void fill(borrow!PacketBuffer buffer, const(ubyte)[] payload) @safe {
    buffer.bytes[0 .. payload.length] = payload[];
}

void send(own!PacketBuffer packet) @safe {
    // The callee has exclusive ownership and must consume or drop packet.
}

void main() @safe {
    own!PacketBuffer packet = PacketBuffer(1500);
    borrow!PacketBuffer writable = borrow packet;
    fill(writable, [cast(ubyte) 'o', cast(ubyte) 'k']);
    send(move packet);
}
```

The example specifies intended syntax and semantics; the current compiler does
not yet parse or type-check it.

### Ownership rules

1. `own!T` owns one initialized `T` value and cannot be copied.
2. `move owner` transfers the value; using the moved-from binding before
   reinitialization is a compile-time error.
3. `borrow!T` is exclusive and mutable. `borrow!const(T)` is read-only and can
   coexist with other read-only borrows.
4. A borrow cannot outlive its owner. An owner cannot move, be reassigned, or be
   dropped while a borrow is live.
5. The owner is dropped exactly once at scope exit or during exception
   unwinding. Moved-from owners do not run the destructor.
6. Drop invokes the value's destructor before releasing the associated storage.
   The allocation policy is part of the owning type/runtime operation and is
   never inferred from a raw pointer.
7. In `@safe` code, references derived from an owner may not escape the checked
   borrow region. Unsafe/foreign operations remain possible only at explicit
   `@trusted` or `@system` boundaries.
8. This extension does not alter ordinary D values, class references, GC
   behavior, or D module semantics.

Ownership checking is a semantic analysis pass over typed AST/control flow.
Lowering makes initialization, borrow start/end, move, and drop explicit IR
operations. Optimization must preserve destructor order and exactly-once drops.
The initial implementation must reject unsupported escape patterns rather than
quietly weakening guarantees.

## Capability map

| Capability | D++ direction | Basis/status |
| --- | --- | --- |
| Procedural, object-oriented, functional and systems code | Coexist in one module and type system | D foundation |
| Classes, constructors, destructors, inheritance and virtual dispatch | Preserve D class and interface semantics; improve checked diagnostics | D foundation |
| Multiple polymorphic contracts | Implement multiple interfaces; no multiple implementation inheritance | D foundation |
| Operator overloading | Preserve D `op*` hooks and define overload resolution centrally | D foundation |
| Templates, specialization, generic constraints | Retain D templates and constraints; improve diagnostics and instantiation | D foundation |
| CTFE, compile-time programming and reflection | Reuse D compile-time execution and introspection; lower generated declarations normally | D foundation |
| Lambdas, closures and higher-order functions | Preserve delegates and function literals | D foundation |
| Arrays, strings, maps and ranges | Reuse D slices, dynamic arrays, associative arrays and ranges | D foundation |
| RAII and deterministic resource lifetime | Add checked `own!T`, borrow, move and drop semantics | D++ extension design |
| Exceptions | Preserve D exceptions and guarantee owner drops during unwinding | D foundation + ownership integration |
| Concurrency, threads and atomics | Reuse D concurrency libraries and atomics; check ownership across thread transfer | D foundation + ownership integration |
| Modules and namespaces | Keep D modules/import visibility | D foundation |
| C and D interoperability | Preserve `extern(C)` / `extern(D)` ABI declarations and test data layout | D foundation |
| Memory layout and low-level programming | Preserve pointers, attributes and explicit `@system` boundaries | D foundation |
| Native optimization and code generation | Typed D++ IR and native backend; no text transpilation | Compiler requirement |

This table is a design and implementation commitment, not a claim that all listed
features are currently implemented.

## Current compiler boundary

The present `dpp` build accepts a subset of function-based source: `int`, `long`,
`bool`, `string`, and selected C pointer types; parameters and local variables;
function calls; arithmetic, comparisons, short-circuit boolean operations;
assignments; `if`/`else`; `while`; and return statements. It recognizes the
selective `std.stdio : writeln` import and lowers that intrinsic to native
formatted output. `extern(C)` prototypes can call native C functions, and
`--link-object` accepts separately compiled native objects.

The compiler does not yet implement general D imports, D's native ABI or runtime,
user-defined aggregates, classes, templates, general CTFE/reflection, ownership,
or concurrency. The ownership syntax above and named examples describing
unimplemented capabilities are design targets only; integration examples must
stay within the actually supported grammar and semantics.
