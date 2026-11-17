# Language support

The current subset includes:

- `Int`, `Bool`, `Float`, `String`, nullable values, and dynamic values
- Local variables, functions, methods, recursion, and expression statements
- Classes, interfaces, anonymous structures, enums, and enum abstracts
- An enum abstract that names its values (`RawRepresentable` or `Flags`) prints its name wherever it becomes a String:
  concatenation, interpolation, `Std.string` and `toString()` (`Button`, `Access[Read | Write]`; an undeclared raw value
  prints as `Kind(9)`, and a nullable one as `null`).
- A switch over an enum abstract without a default covers every declared value, as one over an enum covers every
  constructor: a missing value is `E1021`, naming it, and a switch that covers them all returns on every path when its
  arms do. A value outside the declared set (a native code newer than its binding, or a cast) throws at the switch.
  `Flags` combine their values, so their switches still need a default.
- A switch over a nullable `Int`, `String` or enum abstract matches `case null` apart from its values; a switch over a
  nullable enum abstract without a default must cover `null` too. A catch-all or capture binds the nullable value.
- `null` in a switch over enums follows Haxe's matcher: the value the switch decides on first need not match `null` (a
  null there throws "Null access"), but a `Null<Enum>` or `Null<Bool>` decided on below it must, by `case null` or a
  pattern that leaves it open: a constructor argument (`case Wait(null):` beside `Wait(Jump(_))` and `Wait(Return)`) or
  a tuple element matched under another element's constructor (`case [Move(_), null]:`). `E1021` names the missing case.
- `@:noReturn` on a function or method declares that a call to it never returns: after `if (value == null) fail();`
  the value is known not to be null, and a function may end in such a call where a `return` would otherwise be due. The
  body must throw (or call another `@:noReturn` function) on every path and contain no `return`, and every override of a
  declared method must be declared too. It is a declaration, never inferred from a body; Haxe ignores the metadata, so
  the same source builds there with a `return` placeholder after the call (which Haxeon accepts).
- `try`/`catch` binding `Dynamic`, `Int`, `Float`, `Bool`, `String`, a class, an interface or an enum
  (`catch (e:haxe.io.Error)`); a clause catches the values of its type and lets the others reach the next clause.
- A nullable `Int`, `Float`, `Bool` or `Int64` reads as the plain type wherever one is needed, null giving its default (0,
  0.0, false), as in Haxe: an assignment, argument or return (`var count:Int = map.get(key)` is 0 for a missing key), an
  arithmetic, bitwise or ordering operand, `++` and `--`, a condition, an array index or a range bound. `==` and `!=` still
  see null, and so does a join: `flag ? map.get(key) : 5` and `[map.get(key), 3]` stay nullable. Because the null goes
  away silently, each such read warns (`W1001`), with a fix that writes the default out (`map.get(key) ?? 0`); a value
  checked against null first does not warn.
- `Array.pop` and `shift` return `Null<T>`, null when the array is empty, as in Haxe.
- Closures with generated environments and shared cells for mutable captures
- Arrays and compiler-owned primitive, string, and reference array operations
- `Map` keyed by `String`, `Int`, an enum, or a struct that conforms to `Hashable`, holding primitive, reference or
  value-class values. A class or interface cannot be a key (classes cannot conform to `Hashable`), so there is no
  identity-keyed map like Haxe's `ObjectMap`.
- Arithmetic, bitwise operations, comparisons, string operations, and casts
- `if`/`else`, `switch`, `while`, `do`/`while`, `for`, `break`, and `continue`
- Capture patterns: `name = pattern` matches what `pattern` matches and binds the matched value, as a whole case
  (`case moving = Fast | Slow:`), an enum payload (`case Group(lead = Circle(_), _):`), an array element
  (`case [first = 1, _]:`) or the pattern of `value.match(...)`. Over alternatives it binds whichever one matched.
- Array iteration and comprehensions
- Exceptions
- Simple `typedef` aliases and generics, including typedefs of anonymous structures that refer to themselves
  (`typedef Tree = {children:Array<Tree>}`), directly, through `Null<>`, in pairs, or per generic instantiation.
- A generic class or interface with a concrete type argument is accepted where the same type with `Dynamic` is expected
  (`Box<Int>` as `Box<Dynamic>`), as in Haxe, including through a base class or an implemented interface. Every instantiation
  of a generic class shares one erased layout. Only a whole `Dynamic` argument on the expected side widens: the other direction,
  differing concrete arguments, and `Dynamic` nested inside an argument (`Box<Array<Dynamic>>`) are still type errors.
- `==` on enums follows Haxe. A constructor without fields denotes one value, so `Dot == Dot` is true however the two values
  came about; values of constructors with fields compare by identity, so `Circle(1) == Circle(1)` is false for two separately
  built values and `Circle(1) == Circle(2)` is false. `Array<Enum>.indexOf` and `remove` use the same rule. For declared value equality, a type must conform to `Equatable`; `==` and `haxeon.Equality.equals` then use the same
  implementation. An enum with no constructor that has fields compares by
  constructor, and so does an abstract over an enum. A value compared with a constructor without fields
  (`error == Overflow`) is compared by constructor too, needing no conformance even when other constructors have fields;
  so is a local initialized with one and never reassigned.
  A null operand equals only another null.
  A cycle that does not pass through a structure (`A = B, B = A`, `A = Array<A>`) is still an error.
- Imports as in Haxe, with two stricter rules. A type that an import of a whole module or package brings in only as a side
  effect cannot silently replace a type the current package declares: using that name is `E1029`, reported at the use, and
  naming the import (`import pack.Module.Type;`) or the module's own declaration settles it. `import pack.Module as M;` is a
  namespace: the module's types are `M.Type` and none come in by their bare names (stock Haxe rejects this form).
- Module-level `var`, `final` and functions, as in Haxe: the module's own code names them bare, and other modules import
  one (`import pack.Settings.hits;`) or write its full path (`pack.Settings.hits`). As an extension stock Haxe rejects, they
  can also be reached through the module's name (`Settings.hits`, `Settings.record()` with `import pack.Settings;`). When the
  module declares a class of its own name with a static of the same name, `Store.count` is that static, as in Haxe, and
  only the full path names the variable, so the extension never changes code Haxe accepts. `haxeon lint --only
  module-namespace` names each use of it, for code that must also compile with Haxe.
- Haxe-compatible `Sys` operations through the stable runtime ABI

Inherited methods share a virtual slot by name. A subclass cannot reuse that name with incompatible
parameters or a result type that breaks the inherited contract, or explicitly make a public method private.
Use a different name for an unrelated helper. Compatible overrides may omit an explicit visibility modifier
and inherit the base method's visibility. These checks also apply after an incremental base-class edit.

String addition, equality, `.length`, `indexOf`, and `substring` use the
compiler-owned runtime ABI. Arrays support checked indexing, `.length`, `copy`,
`concat`, `slice`, `indexOf`, `exists`, `push`, and `pop`. Capacity-aware array growth
preserves object identity so aliases and fields continue to observe the same
array. `exists(predicate)` short-circuits at the first match and evaluates its receiver and predicate once.

Converting `Dynamic` to an anonymous structure checks required fields and field types, then copies them into
compiler-owned record storage. Nested records and record fields containing arrays of records are copied recursively. Direct array casts
remain checked storage views and preserve their identity. Optional missing
fields remain null, and malformed fields raise a Haxe exception identifying the field. Recursive structural
copy targets are rejected with E1016; convert their recursive fields explicitly. Typed recursive structures
remain supported. These conversions, dynamic object literals, and field reflection are tested on HashLink,
Wasm32, and Wasm GC.

On HashLink, an in-capacity typed array push and in-range `Bytes.get`/`set` use inline instructions. Growth and
byte-access errors use the existing runtime functions. Reference pushes retain the managed write barrier.

HashLink strings use HashLink's standard `String` object layout: zero
terminated UTF-16 data plus its length in code units, so `.length` and
`charCodeAt` take constant time. Haxeon rejects NUL code units when creating a
`String` from a character code or byte buffer, and rejects NUL in compiled
string constants. Use `Bytes` for binary data.

Hosts may register typed HashLink natives with `Compiler.registerNative()`
before the first build. Registrations then freeze so the native-table layout
cannot silently change beneath a live module. `compiler.RuntimeAbi.register()`
installs the stable host surface used by the command-line compiler; Haxeon-owned
realtime operations remain in a separately versioned ABI.

Unsupported ABI combinations produce explicit typed diagnostics instead of
silently falling back to dynamic behavior.

## Not yet supported

Haxe that stock Haxe 4.3.7 compiles and runs but Haxeon rejects (checked 2026-11-15 by compiling small programs on
HashLink):

- `using` static extensions: `using StringTools;` is a parse error.
- Indexing a `Dynamic` value, such as a parsed JSON array (`json.items[0]`): `E1015`. Convert it to a typed array first.
- Structure patterns (`case {x: 0, y: y}:`) and extractor patterns (`case parse(_) => value:`).
- Rest parameters (`function sum(...values:Int)`).
- Width subtyping between structures: a structure with more fields where one with fewer is expected
  (`var arm:{final value:Int;} = item;` for an `item` with more fields) is a type mismatch. It waits for structures
  lowered as views of one object, so the narrower value is the same object (`docs/design/STRUCTURE_VALUES.md`, step 4);
  the differential case `anonymous-width-subtyping` records it.
- In the standard library: `haxe.ds.List`, `haxe.ds.Vector`, `Lambda.fold`, the file handles of `sys.io.File.read` and
  `write` (`getContent` and `saveContent` work), and the `Type` API (`typeof`, `getClass`, `getClassName`): it needs
  class and enum values (`Class<T>`, `Enum<T>`), which Haxeon does not have yet.
- A method whose return type would be inferred from `++field` (`function next() return ++i;`): `E1020`. Declare the
  return type.
- A lowercase name in a pattern that is also a function or variable in scope is read as that value instead of capturing
  (`case Box(size):` beside a function `size`). Haxe captures; rename the binding.

Stricter than Haxe:

Haxeon is stricter than Haxe only where Haxe's code would fail when it runs. Where Haxe has defined behaviour, Haxeon
follows it, as with the scalar defaults of `Null<Int>` above (which follow Haxe's static targets; on JavaScript the
value stays null), and a warning can point out a surprising case.

- References are null-safe: a field of a `Null<T>` is read only where a null check proves it present (`E1005`). Haxe
  reads through and throws "Null access" when the program runs.
- Map keys must be `Hashable` (above). The rule stays for structs, but Haxe's identity-keyed maps (`ObjectMap`, a class
  instance as key) have no Haxeon equivalent yet; one is planned.
- A statement after a `try` whose every branch returns is `E1012` (unreachable); Haxe accepts it. This one does not meet
  the rule, so it is due to become a warning.

An unannotated field's type is its initializer's, typed when something first needs it, as in Haxe. Where Haxe would let a
later use in another function fix that type, Haxe's result depends on the order it types functions in, so Haxeon asks for
an annotation instead (`E1002`, docs/design/LAZY_DECLARATION_TYPING.md, the user's decisions):

- A type the initializer leaves open: `static var e = [];`, `static var m = new Map();`, `static var n = null;`
  (`Cannot infer the type of field "C.e": nothing in its initializer fixes ...; annotate it`).
- Fields whose initializers need each other's type (`static var a = b + 1; static var b = a + 1;`), which Haxe types as
  `Dynamic` or, when one of them fixes the type, as that type. The error is on the first of them in declaration order and
  names the others; annotating one of them is enough.
- In a generic class, an initializer whose type the class's type parameters cannot express (a structure mentioning one):
  the class's initializers are compiled with the parameters erased, so the type is read from typing it with them.

Planned with these rules: a way to silence `W1001`, per project or per expression, for code that relies on the defaults
on purpose; and fixing the pattern capture that reads a function or variable of the same name (above).

## C header import

A standalone Clang-based importer can generate deterministic, target-specific
raw HXI declarations from a constrained C ABI. It preserves record layouts and
keeps system-header implementation details out of the generated interface. A
strict parser validates types, layouts, symbols, and ABI metadata before use. See
[C header FFI import](C_HEADER_FFI.md) for usage and the supported subset.
The runtime also contains a restricted libffi-based ordinary-C symbol bridge;
the pinned vendored libffi is statically linked into the runtime library, with
no separate libffi runtime dependency. Windows x64 builds compile the pinned
sources directly with CMake and MSVC, without a Cygwin build dependency. This
remains deliberately separate from HashLink's `@:hlNative` convention.

The native-memory model keeps GC-managed Haxe objects separate from fixed-layout
native records. See [native values and memory](NATIVE_MEMORY.md) for the
representation contract and implementation sequence. The frontend recognizes
`@:value @:repr("C")` records, shares ABI layout rules with HXI, and folds
`sizeof`, `alignof`, and `offsetof` queries to constants. HashLink now lowers
typed `RawPtr<T>` memory operations to SSA loads, stores, and offsets, and the
Haxeon `Arena` provides stable bump-allocated native blocks.

## Source-declared HashLink bindings

Target functions can be declared without a Haxe body by combining `extern`
with `@:hlNative`:

```haxe
@:hlNative("std", "sys_time")
extern function nativeTime():Float;
```

The two metadata arguments are the HashLink library and exported symbol.
Bindings participate in normal name and type checking, but emit only a native
table entry. Missing, duplicate, non-string, or malformed bindings are compile
errors. Static methods on `extern class` and static or instance methods on
`extern abstract` use the same form; an instance abstract method passes its
underlying representation as native argument zero.

An extern class or abstract can provide a default library for all its methods.
The method name is used as the native symbol unless the method carries its own
two-argument `@:hlNative` binding:

```haxe
@:hlNative("platform")
extern class Native {
    public static function poll():Int;

    @:hlNative("override", "renamed")
    public static function draw():Void;
}
```

An extern abstract can declare its HashLink storage independently of its source
identity:

```haxe
@:hlType("bytes")
extern abstract Bytes(Dynamic) {}

@:hlType("nativeAbstract")
extern abstract Abstract<T>(Dynamic) {}
```

The supported representations are currently `bytes` and `nativeAbstract`.
Tagged types such as `hl.Abstract<"realtime_module">` use the latter and retain
the quoted tag as part of their ABI identity. These target declarations live
under `stdlib/hl`; unsupported representation names are diagnosed rather than
silently lowered as ordinary objects.

