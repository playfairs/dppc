# D++ language and compiler architecture

D++ is an extension of D, not a source-to-source wrapper and not a second language
that merely borrows D syntax. The design rule is to preserve D's module model,
type system, contracts, templates, CTFE, introspection, ranges, delegates,
attributes, and systems-programming controls wherever they work well, then add
capabilities where D++ has a clear semantic improvement to make.

This document describes the target architecture. It does not imply that all
stages or language features are implemented in the current bootstrap compiler.

## Current implementation status

The executable compiler has a working end-to-end core for one source module:

* The source reader accepts `.dpp` and `.d` files.
* The lexer handles identifiers, decimal integers, escaped string literals,
  line/block comments, punctuation, and the implemented multi-character
  operators.
* The parser builds an AST for module declarations, a restricted selective
  `std.stdio : writeln` import, functions, structs with scalar/pointer and
  previously declared struct fields, fixed arrays of structs, overloaded
  constructors, instance methods, `~this()` destructors, local declarations,
  member/index access, calls, assignments, unary/binary expressions, `if`,
  `while`, and returns.
* Symbol/type analysis resolves functions, struct members, fields, and locals;
  computes nested aggregate layout and destructibility metadata; selects
  constructor/method overloads; and checks call arity, conversions, field/index
  assignments, conditions, and return paths. The only import resolved today is
  the compiler-provided `writeln` intrinsic.
* The parser and semantic pass support D-compatible `scope(exit) expression;`
  cleanup for the current expression subset. Lowering records cleanup actions
  per lexical scope and emits them in reverse registration order on fallthrough
  and return, including nested scopes and loop-body iterations. `break` and
  `continue` are semantically checked against loop nesting and lower through
  cleanup for the scopes they exit. Default-initialized struct locals with a
  `~this()` or a destructible member register destructor calls in the same
  cleanup sequence, so explicit cleanup and destruction preserve one LIFO
  order. Struct storage is zero-initialized, nested struct fields (and fixed
  array elements) are constructed in declaration/index order, then the
  explicitly selected outer constructor runs. A destructor body runs before
  its members are destroyed in reverse field order; fixed-array elements are
  destroyed in reverse index order. Types that need member destruction receive
  a synthesized typed destructor function.
* CTFE folds pure literal integer arithmetic and comparisons. The IR optimizer
  performs additional integer and comparison folding.
* Lowering builds typed operations and explicit labels/branches, including
  short-circuit boolean control flow. The LLVM backend emits LLVM IR and the
  linker invokes Clang to produce a native executable.
* `extern(C)` prototypes/calls support the currently modeled primitive and
  pointer types. `--link-object` lets callers provide additional native object
  files, including a D object deliberately exported with C linkage.
* Generated executables link the C ABI runtime. Their native entry point
  initializes the runtime, invokes D++ `main`, and finalizes the runtime before
  returning the program's exit status.
* The runtime provides thread-safe process lifecycle state; aligned, zeroed,
  and reallocating allocation; paired custom allocator hooks; invalid/double
  free detection; live-allocation counters; and fatal panic diagnostics.
  Allocation is explicit and does not impose one memory-management strategy
  on D++ programs.
* The driver supports native output, `--check`, `--emit-ir`, `--run`, and
  explicit link objects. Invalid source and native compiler failures return a
  nonzero status.

The current IR is a typed linear instruction sequence with explicit block
labels, branches, and phi operations; it is not yet a verified, target-neutral
SSA IR. Implemented aggregate support includes scalar/pointer fields, nested
previously declared struct fields, fixed arrays of structs with compile-time
literal indexing, constructors with overload selection, instance methods with
an implicit reference receiver, explicit destructors, and synthesized
destructors for destructible members. Values are zero-initialized before
subobject construction; subobjects are constructed in declaration order before
the containing constructor runs. An explicit destructor body runs before
reverse-order member destruction. Struct parameters and returns are diagnosed
until their ABI and ownership/copy semantics are defined; whole-struct copying
and assignment remain rejected. Dynamic array indices, constructors with
member-initializer lists, exception unwinding, classes, ownership checking, and
dynamic type metadata are not implemented. There is no arbitrary D module
loader, D runtime interoperability, templates, full CTFE, or optimization
pipeline beyond constant folding. Those remain planned stages, not implemented
capabilities.

## Language identity and compatibility

* `.dpp` selects D++ mode. It accepts D-compatible constructs and enables D++
  extensions.
* `.d` selects D compatibility mode. It must not silently acquire D++-only
  semantics. D modules remain ordinary D modules when imported by D++.
* Both modes share source locations, tokens, syntax nodes where their semantics
  agree, symbol identities, type representations, diagnostics, and backend
  infrastructure. Nodes and declarations retain their source dialect so
  diagnostics and compatibility checks can distinguish their origin.
* D's `extern(C)` and `extern(D)` calling conventions and data-layout rules are
  represented explicitly. Interoperability is governed by ABI declarations,
  not by rewriting source or assuming all D and D++ types are layout-compatible.
* A D++ extension that changes the meaning of a D construct must be explicit in
  the language design and represented in semantic analysis. It must not alter
  the meaning of existing D code by accident.

## Compilation pipeline

Each stage consumes a typed, documented interface and produces an explicit
artifact. Stages report diagnostics and preserve source spans; they do not hide
errors behind fallback output.

| Stage | Input → output | Responsibility |
| --- | --- | --- |
| Source manager | paths/bytes → source files | File identity, encoding policy, line tables, imports and source spans |
| Lexer | source → tokens/trivia | D and D++ tokenization, comments, literals, operators, lexical diagnostics |
| Parser | token stream → syntax AST | Grammar, recovery, declarations and expressions; no name/type assumptions |
| AST normalization | syntax AST → canonical AST | Normalize equivalent syntax while preserving dialect, attributes and source locations |
| Module loader | imports → module graph | Resolve D and D++ modules, cycles, visibility and package/module identity |
| Declaration collection | modules → symbol graph | Register declarations before resolving bodies; scopes and overload sets |
| Name resolution | AST + symbol graph → bound AST | Resolve identifiers, imports, members, overload candidates and accessibility |
| Type checking | bound AST → typed AST | Type construction, inference, conversions, generic constraints and overload resolution |
| Semantic analysis | typed AST → checked program | Contracts, inheritance, interfaces, effects/safety, ownership/borrow checking and ABI rules |
| CTFE | checked expressions → constants | Evaluate permitted compile-time code under deterministic resource limits |
| Generic instantiation | generic declarations + arguments → instances | Instantiate, specialize, cache, diagnose recursion and preserve source provenance |
| Reflection/code generation | semantic metadata → declarations/constants | Compile-time introspection and explicitly requested generated declarations |
| D++ IR lowering | checked program → typed IR | Lower language constructs to explicit control flow, calls, memory/ownership operations and ABI forms |
| Optimization | typed IR → optimized IR | Semantics-preserving transformations; debug/source mapping retained |
| Backend | optimized IR → object files | Native target code, calling conventions, data layout and debug information |
| Link driver | object files/libraries → executable/library | System linker invocation, runtime/library selection and surfaced linker diagnostics |

### Frontend contracts

The parser builds syntax only. The AST can express D declarations and D++ additions
without encoding machine instructions. Name resolution and type checking are
separate passes: forward declarations and overload sets are collected before bodies
are checked. Types are canonical compiler objects, not strings; declarations are
identified by symbols rather than repeatedly looked up by spelling.

The semantic program records resolved calls, selected overloads, conversions,
template arguments, ownership operations, virtual slots, exception edges, and
source spans. Lowering consumes this checked representation. It never reparses
text or relies on textual substitutions.

### D++ intermediate representation

The typed IR has explicit basic blocks and terminators, SSA-capable values,
aggregate and target-layout descriptions, typed loads/stores, direct and virtual
calls, exception/control-flow edges, and source/debug locations. D++ ownership is
lowered to explicit move, borrow, initialization, and drop operations before
optimization. The IR must make aliasing and observable destructor behavior
available to optimizers; optimization may not elide or reorder a required drop.

The IR is target-independent except for target layout and ABI queries. A backend
consumes IR, not AST text. Backend and linker selection belong to the driver and
target configuration rather than the parser.

## Semantic subsystems

### Types and overloads

The type model includes D-compatible built-ins, qualifiers, pointers, arrays and
slices, associative arrays, tuples, delegates/function types, structs, classes,
interfaces, enums, unions, template parameters and instantiated types. `const`,
`immutable`, `shared`, `scope`, `@safe`, `@trusted`, and `@system` remain semantic
properties, not decorative tokens. Conversions and overload ranking are specified
centrally so calls, operators, templates and delegates agree.

D's templates and constraints are the generic foundation. D++ should enhance
constraint diagnostics, specialization selection, instantiation performance,
and introspection without creating a competing concepts syntax. CTFE evaluates
the same checked language subset under explicit limits; it is not an ad hoc
second interpreter for templates.

### Object model

Structs remain value types with explicit layout and user-defined operations.
Classes retain D's reference semantics, single class inheritance, interfaces,
virtual dispatch and `final`/`abstract` controls. Multiple inheritance of
implementation is not introduced: D interfaces already express multiple
polymorphic contracts without the layout and base-subobject ambiguities of
C++-style multiple inheritance. Constructor/destructor semantics and dispatch
are represented in the semantic model and IR, not injected as source text.

### Ownership and deterministic lifetime

D++ adds opt-in ownership for code that needs deterministic resource lifetime
without replacing D's GC or ordinary D references:

* `own!T` is a unique owner of a `T` resource. It is non-copyable; `move owner`
  transfers it and leaves the source uninitialized until reassigned.
* `borrow!T` and `borrow!const(T)` are non-owning mutable and read-only views.
  Their lifetime is bounded by the owner and borrow region. A mutable borrow is
  exclusive; shared read-only borrows may coexist. Moving or dropping the owner
  while a borrow is live is rejected.
* An initialized owner is dropped exactly once on normal scope exit and during
  exception unwinding. Drop glue invokes the resource's destructor and then
  releases its storage according to its declared allocation policy. A moved-from
  owner is not dropped. `scope(exit)` remains available for local cleanup and is
  not a substitute for ownership checking.
* Ownership checking is enforced in `@safe` code. Explicit unsafe operations and
  foreign boundaries require `@trusted` or `@system` as appropriate. D values
  without `own!` keep D lifetime and GC behavior.

These are D++-specific language semantics, currently a design target rather than
implemented compiler functionality. Their rules must be specified before the
feature is enabled by the frontend.

### Errors, modules, and native boundaries

D exceptions and `try`/`catch` remain the compatible default. D++ deterministic
drop guarantees apply on unwinding. A future result type may be supplied by the
standard library; it does not replace exceptions in the language core.

D modules remain the organizing and visibility unit. Imports form a resolved
module graph, with D++ modules able to consume D declarations through a D
compatibility boundary. `extern(C)` and `extern(D)` declarations retain exact
calling convention, linkage, and layout metadata through lowering and linking.
Raw pointers and manual layout remain available for systems code, subject to
D's safety annotations and D++ ownership rules.

## Runtime and standard library boundary

The standard library is a separately versioned layer over compiler-provided
primitives. It builds on Phobos and D's existing ranges, algorithms, strings,
collections, concurrency and atomics where compatibility permits. D++ additions
must compose with those APIs rather than requiring a parallel replacement
library. Runtime selection, GC use, exception support, thread support and ABI
requirements are explicit target properties.

## Implementation milestones

1. **Frontend foundation:** expand the current source manager, token model,
   grammar, AST, diagnostics, and tests toward the D-compatible language.
2. **D semantic baseline:** declaration collection, name/type resolution,
   expressions, functions, structs, modules/imports and D compatibility tests.
3. **Executable baseline:** evolve the current LLVM emitter into typed verified
   IR, with robust lowering, debug locations, and end-to-end regression tests.
4. **D++ ownership:** ownership types, borrow checker, move/drop IR operations,
   unwinding integration and negative lifetime tests.
5. **D object/generic model:** classes, inheritance, virtual dispatch, template
   instantiation, constraints, CTFE and reflection conformance.
6. **Runtime/library integration:** D and C ABI tests, exceptions, standard
   library integration, concurrency, atomics and platform/runtime coverage.
7. **Optimization and tooling:** optimization correctness, incremental build
   graph, debug quality, formatter/LSP interfaces and conformance suites.

Each milestone adds runnable positive and negative tests and does not advertise a
feature as supported until parser, semantic, lowering, and end-to-end coverage
exist where applicable.
