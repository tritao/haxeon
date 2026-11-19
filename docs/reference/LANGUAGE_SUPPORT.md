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
- A switch over a nullable `Int`, `String` or enum abstract matches `case null` apart from its values. A catch-all or
  capture binds the nullable value. Without a default, a switch over a nullable enum abstract covers its values but need
  not match `null`, as one over a `Null<Enum>` need not: a null its arms leave throws "Null access" (Haxe 4.3.7 on
  HashLink leaves it unmatched and goes on past the switch). A value pattern matches a nullable enum abstract argument
  by name (`case Maybe(A):`), and naming every value there covers the constructor, as naming every constructor does.
- A tuple switch (`switch [a, b]`) without a default covers every tuple when it is used as a value. As a statement it follows
  Haxe's matcher: the first element it decides on may leave values of an Int or String unmatched (such a tuple runs no case),
  but the values its cases name must each be covered in the later elements, and an enum or Bool element must be covered
  constructor by constructor (`E1021` names a missing tuple, `[1, Circle]`).
- Structure patterns, `case {x: 0, y: y}:`, on a structure or a class instance, as Haxe matches them: a case matches the
  fields it names, each against its own pattern (a constant, an enum pattern, a capture, `_`, or a nested structure,
  `{at: {x: 1}}`), and `p = {x: 0}` or `{at: inner = {y: 1}}` captures the value or a field. Their coverage is a tuple
  switch's over the fields the cases name (above): an enum field is covered constructor by constructor, an Int field only
  by `_` (or, in a statement, not at all). A case of such a switch is a structure pattern, a capture, `_` or `null`:
  `case null:` matches a null subject before any field is read (the first case that matches null runs: `null`, `_` or a
  name). `E1021` names a missing case as a structure of the fields the cases read (`{shape: Square}`).
- A switch over any other value (a class instance, a structure, a function) whose cases are only `_`, names, captures of
  them, or `null`, as Haxe allows (`switch point { case null: ...; case p: ... }`).
- Extractor patterns, `case expression => pattern:`, as Haxe matches them: `expression`, in which `_` is the value
  (`_.length => 3`, `parse(_) => Some(value)`), is evaluated only when no earlier case matched, once for a run of cases
  that share it, and its value must match `pattern`; `name = expression => pattern` also binds the value. The cases after
  them match the value itself again. Coverage is that of each run's value (an enum constructor by constructor). An
  extractor may stand inside another pattern, where `_` is the part it replaces: an enum argument (`Some(_.length => 3)`),
  an array or tuple element (`[_ * 2 => 4, _]`), a structure field (`{name: _.length => 3}`) or a `.match` pattern. Such a
  case matches its outer pattern first; consecutive cases that differ only in the extractor's pattern evaluate it once, as
  Haxe does, and one whose pattern cannot fail (`_.length => n`) covers what the outer pattern covers. In a tuple switch,
  as in Haxe, an extractor reads an element, never the whole tuple (`case _.length => 2:` there is `E1019`).
- A switch over `Bool` without a default covers `true` and `false` (`E1021` names the missing one), as a statement too,
  and lowers to a branch on the value. One over `Null<Bool>` need not match `null`: a null reaches `case null`, the
  default or an unguarded catch-all when the switch has one, and otherwise reads as `false`, as Haxe's `if (subject)`
  does on HashLink.
- `null` in a switch follows Haxe's matcher: the value the switch decides on first need not match `null` (a null
  there throws "Null access"), but a `Null<Enum>`, `Null<Bool>` or nullable closed enum abstract decided on below it
  must (Haxe 4.3.7 fails with `Not_found` naming a missing one of the last kind; Haxeon reports it), by `case null` or a
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
- Haxe's `Lambda` over arrays, maps and iterables, `flatten` and `flatMap` included. A callback's result that names a type
  parameter nothing has fixed yet is a type variable its body fills, as in Haxe: `Lambda.flatMap(words, w -> w.split(""))`
  returns an array as the `Iterable<S>` it declares, and a statement body makes it Void.
- Arrays and compiler-owned primitive, string, and reference array operations
- `Map` keyed by `String`, `Int`, an enum, or a struct that conforms to `Hashable`, holding primitive, reference or
  value-class values. A class or interface cannot be a key (classes cannot conform to `Hashable`), so there is no
  identity-keyed map like Haxe's `ObjectMap`.
- Arithmetic, bitwise operations, comparisons, string operations, and casts
- `if`/`else`, `switch`, `while`, `do`/`while`, `for`, `break`, and `continue`
- Capture patterns: `name = pattern` matches what `pattern` matches and binds the matched value, as a whole case
  (`case moving = Fast | Slow:`), an enum payload (`case Group(lead = Circle(_), _):`), an array element
  (`case [first = 1, _]:`). Over alternatives it binds whichever one matched.
- `value.match(pattern)` on an enum value (a constructor without arguments too, `Empty.match(_)`) says whether the value,
  evaluated once, matches the pattern: nested patterns, constants, `_` and alternatives (`Circle(_) | Rect(1, _)`). As in
  Haxe, the pattern binds no names: a capture there (`shape`, `Circle(radius)`, `s = Circle(_)`) is `E1019`, "Pattern
  variables are not allowed in .match patterns".
- A lowercase name in a pattern captures, as in Haxe, even where a function, local, static or field of that name is in
  scope (`case Box(size):` beside a function `size`): inside the case the name is the captured value.
- Array iteration and comprehensions
- Static initialization runs in Haxe's order: every class's `static function __init__()` first, then the static
  initializers, class by class, each class's in declaration order. Classes go module by module in path order, each
  module's in declaration order, after the classes their static initialization reaches (a base class, and the classes
  whose statics, static methods or constructors it uses). A static read before its initializer runs reads its default
  (`0`, `false`, `null`), and initializers that read each other in a cycle compile, as in Haxe. Such a cycle warns as
  Haxe does (`W1002`, "maybe loop in static generation of A", at the class), once per class where Haxe repeats it.
- Exceptions. `haxe.Exception`'s `details()` and `stack`, and `haxe.CallStack`, print Haxe's HashLink format, except
  that a static method's frame names its class in the `$Class` form, a lambda's frame has another name, and inlined
  frames differ.
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
- `private` as in Haxe: a member written without `public` is private to its class and its subclasses (an interface's
  members, an extern class's and those of a class with `@:publicFields` are public), and `@:allow`, `@:access` and
  `@:privateAccess` grant access as Haxe does. Reaching a private field, method or constructor elsewhere is `E1030`, with
  Haxe's message (`Cannot access private field secret`, `Cannot access private constructor of Item`), and so is a `for`
  loop over a class whose `iterator()` is private. An override written without a modifier keeps the overridden method's
  visibility, and a class without a constructor of its own is constructed through its base's, as in Haxe. A private
  module-level variable is visible in its own module.
- Static members belong to the class that declares them, as in Haxe: a subclass does not inherit them, so its code names a
  base class's static through that class (`Base.count`, `Base.make()`), and `Derived.count` or a bare `count` in Derived
  does not reach it.
- Properties on an abstract, as in Haxe: `public var length(get, never):Int;` with `function get_length() return
  this.length;` is read as `stack.length` and, with `set`, written as `stack.top = 1`, `stack.top += 1` or `stack.top++`,
  from outside and from the abstract's own methods (`length`). Each access calls the accessor; `never` forbids it. An
  abstract stores nothing but its underlying value, so its variables must be such properties (`Cannot declare member
  variable in abstract`, `Member property accessors must be get/set or never`, `Method get_length required by property
  length is missing`, in Haxe's words).
- Static variables and finals on an abstract (`static var count = 0`, `static final step = 2`, `static inline var`), read and
  written through the abstract (`Counter.count`, `pack.Counter.count`) and bare in its methods. Haxe keeps them in the
  abstract's implementation class; Haxeon in a hidden class of the module (`AbstractStatics`), which goes where the abstract
  is declared among the module's classes, so they initialize in Haxe's order (below), and a class whose initializers
  reach one of the abstract's statics or static methods initializes after them.
- Properties of a class, static or instance, and static properties of an abstract (`var label(get, set):String`,
  `static var count(get, set):Int`), as in Haxe: a `get`, `set` or `dynamic` side calls its accessor wherever source names
  the property (`item.label`, `Counter.count`, bare in its own class, `+=`, `++`, `x++` as a value), an instance accessor
  as a method, so an override is called; inside the accessor of that side the property of `this` is its variable (an
  `@:isVar` property's), so a read in `set_x` still calls `get_x`. A `never` side cannot be accessed, a `null` side only
  from the class and its subclasses (or `@:allow`, `@:access`), a missing accessor is reported, and so is the variable of a
  property without storage, in Haxe's words and at its places.
- Variables and properties in an interface (`interface Shape { var x:Int; var area(get, never):Int; }`), as in Haxe: an
  implementing class has each, public, with an access that unifies with the interface's (each side the same, or the
  interface's `null` or `never`) and the same type, and the accessors of its `get` and `set` sides, in Haxe's words and at
  its places. An access through the interface calls a method of the interface, the property's accessor or, for a
  variable, a hidden accessor each implementing class is given, so it reaches the object's variable or accessor on every
  backend; a `null` side cannot be accessed through the interface, even inside an implementing class (Haxe allows that).
- An assignment used as a value (`(item.label = "x")`, `(item.count += 1)`, `++item.count`, `a = b = 0`) has Haxe's
  value: the result of the setter where a property's setter stores it, else the value stored, as the target's type.
- An abstract's implicit conversions, as Haxe casts them: through the expected abstract's `from` conversions, else the
  value's abstract's `to` conversions, a `@:from` or `@:to` function before a `from` or `to` type. Where the other side
  is not an abstract (Int, Float, a class), the value meets the conversion's type as Haxe unifies it, so an Int meets a
  Float and a class its base class or interface (`var r:Root = 81` with `abstract Root(Float) from Float`); one abstract
  never converts to another through a third type.
- `(value : Type)` is Haxe's type check: the value is typed with `Type` expected (`([] : Array<Int>)`, `(null : Null<Foo>)`),
  must unify with it as an assignment does (`("a" : Int)` and `(base : Derived)` are errors), converts implicitly (an Int to a
  Float, an abstract through a `@:to` or `@:from`), and the expression has `Type`. `cast` and `cast(value, Type)` cast.
- Every function and method is typed, as in Haxe, whether or not anything calls it, so an error in one nothing calls is
  reported: an instance method or constructor of an abstract, and a generic function or method (a class's, an abstract's
  static one, a module-level one), which is typed once with its type parameters as themselves. Its code is still each
  call's specialization. There a member of a value of a type parameter is its constraints', in the order written
  (`function measure<T:Measured>(value:T) return value.measure()`, `T:Readable & Writable`), and `T has no field x` when
  none has it; `sizeof<T>`, `alignof<T>`, `offsetof`, `typeInfo<T>` and `RawPtr<T>` layouts, and the members Haxeon
  synthesizes for `T:Flags` and `T:RawRepresentable`, are left to each specialization, which checks them.
- `new Box(values)` of a generic abstract infers its type arguments as Haxe does: from the constructor's arguments, a
  parameter they leave open (`new Box([])`) from the expected type (`var box:Box<Int> = new Box([])`).
- Module-level `var`, `final` and functions, as in Haxe: the module's own code names them bare, and other modules import
  one (`import pack.Settings.hits;`) or write its full path (`pack.Settings.hits`). As an extension stock Haxe rejects, they
  can also be reached through the module's name (`Settings.hits`, `Settings.record()` with `import pack.Settings;`). When the
  module declares a class of its own name with a static of the same name, `Store.count` is that static, as in Haxe, and
  only the full path names the variable, so the extension never changes code Haxe accepts. `haxeon lint --only
  module-namespace` names each use of it, for code that must also compile with Haxe.
- Haxe-compatible `Sys` operations through the stable runtime ABI
- Rest parameters, as in Haxe: the last argument of a function, method, constructor, local function or static extension
  may be `...values:T`, a `haxe.Rest<T>` (`values[i]`, `values.length`, `for (value in values)`, `toArray()`, `append`,
  `prepend`, `haxe.Rest.of(array)`). A call passes the arguments from its position on one by one (`sum(1, 2, 3)`, `sum()`),
  or spreads an array (`sum(...numbers)`, which the rest then shares, as on Haxe's targets); a generic rest infers its type
  from them. On HashLink and Wasm the rest is the array itself. A function type writes one as Haxe does, `(...Int)->Int`
  or `(...values:Int)->Int`, which is `haxe.Rest<Int> -> Int`: a call through such a value packs its arguments too.
- Indexing a `Dynamic` value (`json.items[0]`, `value[i] = v`, `value[i] += 1`, `value[i]++`), as Haxe does on HashLink:
  the index is an Int, a read gives the element of the array the value holds as Dynamic, or null past its end, and a
  write stores there, growing the array. A null value is a null access, and a negative index or a value that holds no array
  fails. `value.length` of an array is its length. As on HashLink, what a write can store is the array's: an array
  literal written where Dynamic is expected (`var a:Dynamic = [1, 2]`) is an `Array<Dynamic>`, as Haxe types it, so a write
  past its end leaves nulls and any value can be stored; a typed array behind Dynamic keeps its element type, so a write past
  its end leaves the type's default (`0`) and a value of another type fails ("Can't cast String to i32" on both).
- Static extensions, as in Haxe 4.3.7: `using pack.Tools;` (a module, whose types and module-level functions it brings, or
  one type, `using pack.Tools.Extra;`) and `@:using(pack.Tools)` on a class, enum or abstract make `value.name(arguments)`
  call `Tools.name(value, arguments)` where the value's type has no member `name`. The order is Haxe's: the value's own
  members, then its type's `@:using` (a class's, then its base class's and interfaces'), then the module's `using`, the last
  first; within a module the last type first and its module-level functions last. A static is passed over when it is
  private to the calling code, `@:noUsing`, or its first argument does not take the value (an abstract's conversions count;
  a `Dynamic` value meets only `Dynamic`). Generic extensions infer from the value (`using Lambda`, `StringTools`), a
  `Null<T>` value is passed as it is where the first argument takes null. A value of a type parameter takes the extensions
  of its constraints (`value.describe()` for `T:Shape`), and `@:using` on a typedef applies to values of the type it names
  (a non-generic typedef; Haxeon types a value by the named type, so it applies to every value of that type, where Haxe
  applies it only to values written with the typedef). An extension read as a value is the extension bound to the value,
  evaluated once there (`var trim = text.trim;`, `var add = n.add;`), as in Haxe; a generic one whose other type parameters
  the value does not fix (`[1, 2].map`) is `E1003` (`using-extension-value-open`). Last come Haxe's global extensions of an
  enum value, `haxe.EnumTools.EnumValueTools` (below), which apply without a `using`. Not yet: a class named as a value
  (`Main.twice()` with a `Dynamic` first argument, which Haxe passes `Class<Main>`) and Haxe's `haxe.EnumTools` on an enum
  itself (`Color.getName()`, `Color.createAll()`): both need the `Type` API's class and enum values
  (`docs/design/TYPE_VALUES.md`).
- The enum part of Haxe's `Type` API, on a value of a known enum type: `Type.enumIndex`, `Type.enumEq`,
  `Type.enumConstructor` (the constructor's name) and `Type.enumParameters` (a new `Array<Dynamic>` of its arguments in
  declaration order, `null` for an optional one left out; writing to it does not change the value, as on HashLink). Haxe's
  `EnumValueTools` give the same as extensions of every enum value: `getName()`, `getParameters()`, `getIndex()` and
  `equals(other)`, tried after the value's own `@:using` and its module's `using`, as in Haxe (a `using haxe.EnumTools`
  puts them at its place in the module's list), and callable as `EnumValueTools.getName(value)`. A `Null<E>` value is
  checked, as a call of a method on it is: null throws "Null access", as Haxe's does. `Type.enumEq` also compares
  `Dynamic` values; the others need the enum's type where they are typed. `Dynamic` and Haxe's `EnumValue` type wait for
  enums as runtime values (`docs/design/TYPE_VALUES.md`).

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

- An arrow lambda's rest parameter (`(...values:Int) -> values.length`), which Haxe also rejects.
- Width subtyping between structures: a structure with more fields where one with fewer is expected
  (`var arm:{final value:Int;} = item;` for an `item` with more fields) is a type mismatch. It waits for structures
  lowered as views of one object, so the narrower value is the same object (`docs/design/STRUCTURE_VALUES.md`, step 4);
  the differential case `anonymous-width-subtyping` records it. The same holds for an object literal once it has met one
  structure: its record is that structure's, so it gains no field from a second structure with other optional fields, nor
  after a narrower use (`structure-open-literal-two-uses`). A literal that meets one structure gains its optional fields,
  as in Haxe (`structure-open-literal`).
- In the standard library: `haxe.ds.List`, `haxe.ds.Vector`, `Lambda.list` (it returns a `haxe.ds.List`), the file handles of `sys.io.File.read` and
  `write` (`getContent` and `saveContent` work), and the `Type` API beyond an enum value's (`typeof`, `getClass`,
  `getClassName`), with Haxe's `EnumValue` type: it needs class and enum values (`Class<T>`, `Enum<T>`), which Haxeon
  does not have yet (`docs/design/TYPE_VALUES.md`).
- A method whose return type would be inferred from `++field` (`function next() return ++i;`): `E1020`. Declare the
  return type.
- A generic call whose type argument is a type variable something after the call still fixes (`var values = [];
  Lambda.count(values); values.push(1);`): `E1003`. Haxeon names and types a generic call's specialization when it types the
  call, so it cannot follow a variable fixed later; one that only the argument's own value carries (`Lambda.empty([])`) is
  Dynamic, as in Haxe. The differential case `lambda-unfixed-before-call` records it.
- Declaring a local again in the same block (`var x = 1; ...; var x = "ten";`): `E1001` (Duplicate local). Haxe accepts
  it, the second declaration shadowing the first for the code after it; a nested block works in Haxeon. The differential
  case `local-redeclared-same-block` records it.
- Reading an `Array` element at or past its length (`var a:Array<Null<Bool>> = []; a[3]`): HashLink throws "Array index
  out of bounds". Haxe gives null there (the type's default value for a basic type on static targets). Writing past the
  end grows the array, as in Haxe. Found on 2026-11-19; the Wasm backends are not checked yet.
- Reading a field of a value whose type is a type variable nothing has fixed yet (`items.length`). Haxe accepts it.
  Reported on 2026-11-17 (not verified on current main).

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
- A duplicate switch case is `E1020` ("Duplicate switch case"); Haxe warns that the case is unused and compiles. This
  one does not meet the rule either.

An unannotated field's type is its initializer's, and an unannotated function's result and arguments are what its body
gives them, typed when something first needs them, as in Haxe: the first value `return` fixes the result, later ones must
match it, `return null` first makes it nullable, and no value return makes it `Void`. Where Haxe would let a later use in
another function fix such a type, Haxe's result depends on the order it types functions in, so Haxeon asks for an
annotation instead (`E1002`, docs/design/LAZY_DECLARATION_TYPING.md, the user's decisions):

- A type the initializer leaves open: `static var e = [];`, `static var m = new Map();`, `static var n = null;`
  (`Cannot infer the type of field "C.e": nothing in its initializer fixes ...; annotate it`).
- A type a function's body leaves open: a lone `return null` (`Cannot infer the return type of function "C.f": nothing in
  its body fixes the type of the null it returns; annotate it`), or an argument only its callers fix, `function g(x) {}`
  called as `g(1)` (`Cannot infer the type of argument "x" of function "C.g": nothing in its body fixes it; annotate it`).
  Haxe takes the first caller's type.
- Declarations that need each other's type: fields (`static var a = b + 1; static var b = a + 1;`), functions
  (`function c() return d() + 1; function d() return c();`), or a field and a function. Haxe types them as `Dynamic` or,
  when one of them fixes the type, as that type. The error is on the first of them in declaration order and names the
  others; annotating one of them is enough. A function that calls itself is typed as in Haxe.
- An object literal's structure gains optional fields only while the function or initializer that wrote it is typed
  (docs/design/STRUCTURE_VALUES.md, decision 3). A literal held by an unannotated field and used elsewhere as a structure
  with more optional fields, `static var config = {name: "x"};` read as `{name:String, ?debug:Bool}`, is an error:
  `{name : String} has no field debug; the structure comes from a literal in "Main.config", which closed its type;
  annotate the type of field "Main.config"`. Haxe keeps the field's structure open, so which use adds a field depends on
  the order it types functions in. A literal returned by an unannotated function gets the same message (`annotate the
  result of ...`); Haxe rejects that one too.
- A field of a value struct or a native value record without a type (`E1022`): its type is part of the layout.
- In a generic class, an initializer whose type the class's type parameters cannot express (a structure mentioning one):
  the class's initializers are compiled with the parameters erased, so the type is read from typing it with them.

Planned with these rules: a way to silence `W1001`, per project or per expression, for code that relies on the defaults
on purpose.

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
underlying representation as native argument zero. So does an `extern` method
without a body in a class or abstract that is not extern itself
(`@:hlNative("std", "math_sqrt") static extern function sqrt(v:Float):Float;`),
which Haxe leaves unimplemented on HashLink. A function with `@:hlNative` and a
body is the native too, as Haxe compiles it on HashLink: the body is typed (its
errors are reported) but never runs. That holds for a class's static method, a
module-level function and an abstract's static or instance method; a class's
instance method is not supported (`E1021`; Haxe leaves it null). Haxeon binds
`@:hlNative` on Wasm as well, as it binds an extern's (the Wasm runtime
provides `haxeon_runtime`'s natives), so the body is not a Wasm fallback: code
that needs one there selects it with `#if wasm`. `@:cNative` still binds only
an extern function (`E1021` names a body, which would run instead).

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

