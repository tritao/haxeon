# Error codes

A diagnostic names the file, line, and column where the compiler found a problem.
The line and column start at one. In `error[E1002]`, `error` is the severity and
`E1002` is the code. Warnings use the same layout with `warning[Wxxxx]`.

```text
src/Main.hx:3:19: error[E1002]: Type mismatch for local "count": expected Int, got String
```

Use the code to find the entry below, then read the message for the details of
your case. Several codes cover a group of related checks. The caret in the full
format points to the affected source, and some diagnostics include a suggested
fix or further details.

`haxeon build` and `haxeon check` use `--diagnostic-format=full` by default.
Use `--diagnostic-format=short` for one line per diagnostic, in the form
`Main.hx:3:19: E1002: message`, with paths relative to the source root.
See the [CLI reference](CLI.md) for build and check options.

## E0000: Editor request failed

The editor service could not read or handle a request. Check that the editor integration sends valid JSON with a method name. For a valid request, the message gives the underlying failure.

## E0001: Invalid source token

This umbrella code covers characters, literals, and comments that cannot be read as Haxe tokens. Check quotes, escape sequences, comment delimiters, and numeric digits or separators near the reported location.

## E0002: Invalid source syntax

This umbrella code covers malformed Haxe syntax, conditional compilation, and embedded text. Check the expected syntax or directive, or confirm that the path passed to Embed.text names a readable UTF-8 file.

## E1000: Conflicting declarations

A declaration conflicts with another declaration, a generated member, or a registered native. Rename or remove the conflicting declaration. For generated members, check which names the conformance reserves.

## E1001: Duplicate parameter or object field

A parameter list or object literal repeats a name. Give the parameters distinct names or supply each field once.

## E1002: Invalid assignment or binding

This umbrella code covers incompatible initializers and assignments, invalid properties and constants, and scoped bindings used outside their allowed lifetime. Match the expected type, fix the declaration, or keep the scoped value inside its scope as indicated by the message.

```haxe
class Main {
	static function main():Void {
		var count:Int = "three";
	}
}
```

## E1003: Unsatisfied type requirement

This umbrella code covers return and function type mismatches, failed inference and generic constraints, and incompatible branches or declarations. Match the types shown in the message or add an explicit type where inference lacks enough information.

```haxe
class Main {
	static function main():Int {
		return "three";
	}
}
```

## E1004: Condition must be Bool

An if, while, do-while, or comprehension condition must be a Bool. Use a comparison or another expression that produces true or false.

## E1005: Invalid name or member access

This umbrella code covers unresolved names, invalid member or property access, and null-safety errors. Check the name and receiver type, and handle a nullable value before using it where a non-null value is required.

## E1006: Invalid function completion

The function can finish without providing its required result, or a function marked `@:noReturn` can return or finish without throwing. Make every reachable path agree with the declared result or control-flow contract. An override or implementation must also preserve the contract.

## E1007: Invalid declaration or modifier

This umbrella code covers declaration and modifier rules, including interface implementation, abstract conversions, properties, and inline closures. It also covers calls to values that are not callable. Check the specific declaration, accessor, or method signature named in the message.

```haxe
interface Step {
	function step():Int;
}

class Counter implements Step {}

class Main {
	static function main():Void {}
}
```

## E1008: Invalid call or arguments

This umbrella code covers incorrect argument counts or names and invalid use of compiler-provided operations. Check the callee, its signature, and any restrictions on the operation.

```haxe
class Main {
	static function main():Void {
		printCount();
	}

	static function printCount(count:Int):Void {}
}
```

## E1009: Invalid argument or conversion

This umbrella code covers incompatible argument and value types and invalid operands to casts, reflection, and other typed operations. Supply a value of the required type or use an explicit supported conversion.

```haxe
class Main {
	static function main():Void {
		printCount("three");
	}

	static function printCount(count:Int):Void {}
}
```

## E1010: Invalid operator operands or string conversion

This umbrella code covers arithmetic, bitwise and abstract operators, and string conversion. Use compatible operands, resolve the ambiguous overload, or convert the value explicitly.

```haxe
class Main {
	static function main():Void {
		var result = true - 1;
	}
}
```

## E1011: Invalid logical operation or comparison

A logical operand or conditional expression needs a Bool, or comparison operands or an abstract comparison result have incompatible types. Use Bool for conditions and logical operators and compare compatible values.

## E1012: Unreachable statement

An earlier statement always leaves the current control-flow path. Remove the unreachable statement or move it before the return, throw, or other exit.

## E1013: Unsupported mutable capture

A write to a captured local would require a mutable capture cell in a context that does not support one. Move the write outside the closure or store the mutable state in a shared object.

## E1014: Invalid index or iteration

This umbrella code covers invalid index expressions and values that lack the required iteration methods. Use the right index type or give the loop a supported iterable, iterator, or map.

## E1015: Array value required

The indexed value must be an array at this use. Check the receiver and its inferred or declared type.

## E1016: Unsupported runtime operation

This umbrella code covers operations the runtime or compiler does not currently support, including some collection element types and generic calls through super. Use a supported type or call form.

## E1017: Loop control outside a loop

A break or continue statement must be inside a loop. Move it into the loop it acts on or use the appropriate control flow for the surrounding code.

## E1018: Invalid increment target

Increment or decrement needs a writable numeric target. Use a mutable numeric variable or a supported numeric field or element.

## E1019: Invalid pattern or deferred control flow

This umbrella code mainly covers switch and match patterns that have the wrong shape, type, or bindings. It also covers control flow that tries to exit a deferred statement. Match the subject and bind each name consistently, or move the exit outside the deferred work.

```haxe
class Main {
	static function main():Void {
		defer {
			return;
		}
	}
}
```

## E1020: Invalid lookup or declaration

This umbrella code covers unresolved types, imports and inheritance, malformed declaration paths, and duplicate switch cases. Check the referenced name or declaration and remove duplicates when the message identifies one.

## E1021: Incomplete switch, invalid throw, or invalid extern

This umbrella code covers missing switch cases, unsupported thrown values, and invalid extern bindings. Add the missing cases or a catch-all pattern, throw a supported non-Void value, or check the extern declaration and its native binding.

## E1022: Invalid native layout or catch clause

This umbrella code covers native storage, layout assertions, ABI and foreign calls, and invalid catch clauses. Check the representation and signature requirements or use a supported catch type and place a Dynamic catch last.

```haxe
@:assertLayout(4)
class Counter {
	public var count:Int;
}

class Main {
	static function main():Void {}
}
```

## E1023: Value may be uninitialized

A local may be read before assignment or an abstract constructor can finish without assigning its underlying value. Initialize the value on every path before the read or exit.

## E1024: Invalid annotation, schema, or field write

This umbrella code covers annotation declarations and arguments, metadata, wire and RPC schemas, and writes to final anonymous fields. Fix the annotation or schema named in the message, or initialize the final field when creating the value.

```haxe
@:discoverMethods
class Main {
	static function main():Void {}
}
```

## E1025: Invalid or missing conformance

This umbrella code covers invalid or missing capabilities such as Equatable, Hashable, Flags, and RawRepresentable, including failed synthesis and recursive requirements. Check the required conformance, member signatures, and the types of fields or enum payloads.

```haxe
enum Direction {
	North;

	public function label():String return "north";
}

class Main {
	static function main():Void {}
}
```

## E1026: Read-only binding or field

A write targets a final local or field or a function binding. Initialize a final value once or use a mutable binding when you need to replace it.

## E1027: Writable value storage required

A mutation or key-path operation needs a writable storage location or a compatible writable path. Apply it to mutable storage or use the path type required by the operation.

## E1028: Generic specialization is too complex

A generic specialization expanded beyond the compiler's type complexity limit. Look for recursion that nests or grows a type argument at each step and keep the recursive specialization's type arguments stable.

## E1029: Ambiguous imported name

More than one import supplies the name used at this location. Qualify the reference, alias an import, or remove the competing import.

## E1030: Inaccessible member

The code cannot access the constructor or member under its visibility rules. Use an accessible API or change visibility if the member is intended to be public.

## E2001: Missing module or type

A module dependency or a type within a module could not be resolved. Check its spelling, package path, module contents, and project source roots or dependencies.

## E3001: Invalid HXI declaration

This umbrella code covers lexical, syntax, and validation errors in HXI foreign interface declarations. Check the indicated declaration and make its types, layouts, and symbols agree with the native interface.

## E4001: Shader compilation failed

The shader tool rejected a source file. Follow its message at the reported location and check included files or target-specific shader rules if relevant.

## E9001: Internal map analysis error

The compiler found a use of a map that its earlier analysis missed. Report the error with a small program that reproduces it.

## W1001: Implicit default for null

Converting a nullable value to its plain type silently substitutes a default when the value is null. Handle the null case or write the intended default explicitly with `??`.

## W1002: Static initialization cycle

Static initialization reaches a class that is already being initialized. Break the cycle or move the dependent work to a later step.

## W1003: Null safety warning

Null safety found a possible null use in a package configured to warn. Guard the value or make the receiving type nullable where null is intended.

## W4001: Shader compilation warning

The shader tool reported a warning for this source location. Read its message and adjust the shader if needed.
