import compiler.abi.PatchPlanner;
import compiler.abi.PatchPlanner.AbiChange;
import compiler.abi.PatchPlanner.PatchDecision;
import compiler.abi.RuntimeAbi.RuntimeAbiDescriptor;
import compiler.abi.RuntimeAbi;
import compiler.abi.RuntimeAbiCodec;
import compiler.abi.AbiChangeSchema;
import compiler.Diagnostic.CompileError;
import compiler.Compiler;

typedef AbiFixture = {
	final name:String;
	final previous:Null<RuntimeAbiDescriptor>;
	final next:RuntimeAbiDescriptor;
	final expected:ExpectedDecision;

	/** Whether the running module takes added functions, as HashLink modules do. */
	final addsFunctions:Bool;
}

enum ExpectedDecision {
	Patch;
	Reload(reason:AbiChange);
}

typedef SourceFixture = {
	final name:String;
	final before:String;
	final after:String;
	final expected:SourceDecision;
}

enum SourceDecision {
	NoOp;
	BodyPatch;
	ReloadFor(reason:AbiChange);
	RejectWith(code:String);
}

class AbiMatrixMain {
	static function main():Void {
		var empty = abi();
		var fixtures:Array<AbiFixture> = [
			fixture("initial load", null, abi(["main" => "()->I32"]), Patch),
			fixture("unchanged ABI", empty, abi(), Patch),
			fixture("function added", empty, abi(["helper" => "()->I32"]), Reload(FunctionAdded("helper"))),
			fixture("function removed", abi(["helper" => "()->I32"]), empty, Reload(FunctionRemoved("helper"))),
			fixture("function signature changed", abi(["main" => "()->I32"]), abi(["main" => "(I32)->I32"]), Reload(FunctionSignatureChanged("main"))),
			fixture("object added", empty, abi(null, ["Editor" => "fields=value:I32"]), Reload(ObjectAdded("Editor"))),
			fixture("object removed", abi(null, ["Editor" => "fields=value:I32"]), empty, Reload(ObjectRemoved("Editor"))),
			fixture("instance field added", abi(null, ["Editor" => "fields=value:I32"]), abi(null, ["Editor" => "fields=value:I32,generation:I32"]),
				Reload(ObjectLayoutChanged("Editor"))),
			fixture("instance field reordered", abi(null, ["Editor" => "fields=left:I32,right:I32"]), abi(null, ["Editor" => "fields=right:I32,left:I32"]),
				Reload(ObjectLayoutChanged("Editor"))),
			fixture("method table changed", abi(null, ["Editor" => "methods=read:Editor.read"]),
				abi(null, ["Editor" => "methods=read:Editor.read,write:Editor.write"]), Reload(ObjectLayoutChanged("Editor"))),
			fixture("base class changed", abi(null, ["Editor" => "base=Node"]), abi(null, ["Editor" => "base=Widget"]), Reload(ObjectLayoutChanged("Editor"))),
			fixture("closure capture changed", abi(null, ["$lambda-env:main:1" => "fields=value:I32"]),
				abi(null, ["$lambda-env:main:1" => "fields=value:I32,offset:I32"]), Reload(ClosureLayoutChanged("$lambda-env:main:1"))),
			fixture("interface changed", abi(null, null, ["Readable" => "methods=read()->I32"]),
				abi(null, null, ["Readable" => "methods=read()->I32;reset()->Void"]), Reload(InterfaceChanged("Readable"))),
			fixture("enum changed", abi(null, null, null, ["Result" => "Ok(I32);Error(Bytes)"]), abi(null, null, null, ["Result" => "Error(Bytes);Ok(I32)"]),
				Reload(EnumChanged("Result"))),
			fixture("static field type changed", abi(null, null, null, null, ["Editor.count" => "I32"]),
				abi(null, null, null, null, ["Editor.count" => "F64"]), Reload(GlobalLayoutChanged("Editor.count"))),
			fixture("lambda edited in place", abi(null, null, null, null, null, ["$lambda:main:main#0" => "a", "$lambda:main:main#1" => "b"]),
				abi(null, null, null, null, null, ["$lambda:main:main#0" => "a", "$lambda:main:main#1" => "c"]), Patch),
			fixture("lambdas shifted by an insertion and a deletion",
				abi(null, null, null, null, null, ["$lambda:main:main#0" => "a", "$lambda:main:main#1" => "b"]),
				abi(null, null, null, null, null, ["$lambda:main:main#0" => "c", "$lambda:main:main#1" => "a"]),
				Reload(GeneratedFunctionsRenumbered("$lambda:main:main"))),
			fixture("lambda edited into a copy of its neighbour",
				abi(null, null, null, null, null, ["$lambda:main:main#0" => "a", "$lambda:main:main#1" => "b"]),
				abi(null, null, null, null, null, ["$lambda:main:main#0" => "a", "$lambda:main:main#1" => "a"]),
				Reload(GeneratedFunctionsRenumbered("$lambda:main:main"))),
			fixture("function adapters shifted by an insertion and a deletion", abi(null, null, null, null, null, [
				"$function-adapter:Ui.register:0" => "a",
				"$function-adapter:Ui.register:1" => "b"
			]), abi(null, null, null, null, null,
				[
					"$function-adapter:Ui.register:0" => "c",
					"$function-adapter:Ui.register:1" => "a"
				]),
				Reload(GeneratedFunctionsRenumbered("$function-adapter:Ui.register"))),
			fixture("lambdas appended after the kept ones", abi(null, null, null, null, null, ["$lambda:main:main#0" => "a"]),
				abi(null, null, null, null, null, ["$lambda:main:main#0" => "a", "$lambda:main:main#1" => "b"]), Patch),
			fixture("lambda fingerprints unknown before the edit", {
				functions: [],
				objects: [],
				interfaces: [],
				enums: [],
				globals: [],
				positional: null
			},
				abi(null, null, null, null, null, ["$lambda:main:main#0" => "a"]), Reload(GeneratedFunctionsRenumbered("$lambda:main:main"))),
			fixture("function added to a module that takes added functions", empty, abi(["helper" => "()->I32"]), Patch, true),
			fixture("function removed from a module that takes added functions", abi(["helper" => "()->I32"]), empty, Patch, true),
			fixture("constructor removed from a module that takes added functions", abi(["Editor.new" => "(Editor)->Void"]), empty,
				Reload(FunctionRemoved("Editor.new")), true),
			fixture("lambda appended in a module that takes added functions",
				abi(["$lambda:main:main#0" => "()->I32"], null, null, null, null, ["$lambda:main:main#0" => "a"]),
				abi(["$lambda:main:main#0" => "()->I32", "$lambda:main:main#1" => "()->I32"], null, null, null, null,
					["$lambda:main:main#0" => "a", "$lambda:main:main#1" => "b"]),
				Patch, true),
			fixture("lambda inserted before another in a module that takes added functions",
				abi(["$lambda:main:main#0" => "()->I32"], null, null, null, null, ["$lambda:main:main#0" => "a"]),
				abi(["$lambda:main:main#0" => "()->I32", "$lambda:main:main#1" => "()->I32"], null, null, null, null,
					["$lambda:main:main#0" => "b", "$lambda:main:main#1" => "a"]),
				Reload(GeneratedFunctionsRenumbered("$lambda:main:main")), true),
			// Such a module takes field and method changes of an object that keeps its kind, base and interfaces; the assembler
			// checks them against the running layout (HlModuleAssembler.planObjects).
			fixture("instance field added in a module that takes added functions", abi(null, ["Editor" => "kind=object;base=null;fields=value:I32"]),
				abi(null, ["Editor" => "kind=object;base=null;fields=value:I32,generation:I32"]), Patch, true),
			fixture("instance field reordered in a module that takes added functions",
				abi(null, ["Editor" => "kind=object;base=null;fields=left:I32,right:I32"]),
				abi(null, ["Editor" => "kind=object;base=null;fields=right:I32,left:I32"]), Patch, true),
			fixture("method added in a module that takes added functions", abi(null, ["Editor" => "kind=object;methods=read:Editor.read"]),
				abi(null, ["Editor" => "kind=object;methods=read:Editor.read,write:Editor.write"]), Patch, true),
			fixture("base class changed in a module that takes added functions", abi(null, ["Editor" => "kind=object;base=Node;fields=value:I32"]),
				abi(null, ["Editor" => "kind=object;base=Widget;fields=value:I32"]), Reload(ObjectLayoutChanged("Editor")), true),
			fixture("interfaces changed in a module that takes added functions", abi(null, ["Editor" => "kind=object;interfaces=;fields=value:I32"]),
				abi(null, ["Editor" => "kind=object;interfaces=Readable;fields=value:I32"]), Reload(ObjectLayoutChanged("Editor")), true),
			fixture("value object field added in a module that takes added functions", abi(null, ["Point" => "kind=value;base=null;fields=x:F64"]),
				abi(null, ["Point" => "kind=value;base=null;fields=x:F64,y:F64"]), Reload(ObjectLayoutChanged("Point")), true),
			fixture("closure capture changed in a module that takes added functions", abi(null, ["$lambda-env:main:1" => "fields=value:I32"]),
				abi(null, ["$lambda-env:main:1" => "fields=value:I32,more:I32"]), Reload(ClosureLayoutChanged("$lambda-env:main:1")), true)
		];
		for (fixture in fixtures)
			assertDecision(fixture);
		// Without the running layout (a compiler resumed from identity state) a field addition still reloads.
		switch PatchPlanner.plan(abi(null, ["Editor" => "kind=object;base=null;fields=value:I32"]),
			abi(null, ["Editor" => "kind=object;base=null;fields=value:I32,generation:I32"]), true, false) {
			case ReloadDomain([ObjectLayoutChanged("Editor")]):
			case other:
				throw 'field added without the running layout: expected a reload, got $other';
		}
		assertReasonSchema(fixtures);
		Sys.println('PASS: ${fixtures.length} ABI compatibility policy fixtures');
		var sourceFixtures:Array<SourceFixture> = [
			sourceFixture("no-op", "function main():Int { return 40; }", "function main():Int { return 40; }", NoOp),
			sourceFixture("body edit", "function main():Int { return 40; }", "function main():Int { return 42; }", BodyPatch),
			// HashLink modules take added functions, so an addition patches.
			sourceFixture("function addition", "function main():Int { return 40; }", "function helper():Int { return 2; } function main():Int { return 40; }",
				BodyPatch),
			// A removed function keeps its slot and body in a HashLink module, so the removal patches.
			sourceFixture("function removal", "function helper():Int { return 2; } function main():Int { return 40; }", "function main():Int { return 40; }",
				BodyPatch),
			sourceFixture("function removal with its caller",
				"function helper():Int { return 2; } function main():Int { return helper(); }", "function main():Int { return 2; }", BodyPatch),
			sourceFixture("function signature", "function helper(value:Int):Int { return value; } function main():Int { return 40; }",
				"function helper(value:Float):Int { return 2; } function main():Int { return 40; }", ReloadFor(FunctionSignatureChanged("Main.helper"))),
			sourceFixture("instance field addition",
				"class Editor { public var value:Int; public function new():Void { this.value = 40; } } function main():Int { return new Editor().value; }",
				"class Editor { public var value:Int; public var generation:Int; public function new():Void { this.value = 40; this.generation = 1; } } function main():Int { return new Editor().value; }",
				BodyPatch),
			sourceFixture("instance field removal",
				"class Editor { public var value:Int; public var generation:Int; public function new():Void { this.value = 40; this.generation = 1; } } function main():Int { return new Editor().value; }",
				"class Editor { public var value:Int; public function new():Void { this.value = 40; } } function main():Int { return new Editor().value; }",
				BodyPatch),
			sourceFixture("instance field type",
				"class Editor { public var value:Int; public function new():Void { this.value = 40; } } function main():Int { return new Editor().value; }",
				"class Editor { public var value:Float; public function new():Void { this.value = 40.0; } } function main():Int { new Editor(); return 40; }",
				ReloadFor(ObjectFieldTypeChanged("Editor.value"))),
			sourceFixture("instance field order",
				"class Pair { public var left:Int; public var right:Int; public function new():Void { this.left = 1; this.right = 2; } } function main():Int { return 40; }",
				"class Pair { public var right:Int; public var left:Int; public function new():Void { this.left = 1; this.right = 2; } } function main():Int { return 40; }",
				NoOp),
			sourceFixture("method addition", "class Editor { public function read():Int { return 40; } } function main():Int { return new Editor().read(); }",
				"class Editor { public function read():Int { return 40; } public function reset():Void {} } function main():Int { return new Editor().read(); }",
				BodyPatch),
			sourceFixture("override addition",
				"class Base { public function new():Void {} public function read():Int { return 40; } } class Editor extends Base { public function new():Void { super(); } } function main():Int { return new Editor().read(); }",
				"class Base { public function new():Void {} public function read():Int { return 40; } } class Editor extends Base { public function new():Void { super(); } override public function read():Int { return 42; } } function main():Int { return new Editor().read(); }",
				ReloadFor(ObjectMethodDispatchChanged("Editor.read"))),
			sourceFixture("base class change", "class Node {} class Widget {} class Editor extends Node {} function main():Int { return 40; }",
				"class Node {} class Widget {} class Editor extends Widget {} function main():Int { return 40; }", ReloadFor(ObjectLayoutChanged("Editor"))),
			sourceFixture("erased generic base argument change", "class Base<T> {} class Editor extends Base<Int> {} function main():Int { return 40; }",
				"class Base<T> {} class Editor extends Base<String> {} function main():Int { return 40; }", BodyPatch),
			sourceFixture("generic abstract representation change",
				"abstract Value<T>(T) from T to T {} function read(value:Value<Int>):Int return 40; function main():Int return read(1);",
				"abstract Value<T>(T) from T to T {} function read(value:Value<String>):Int return 40; function main():Int return read(\"one\");",
				ReloadFor(FunctionSignatureChanged("Main.read"))),
			sourceFixture("alias-equivalent generic abstract argument",
				"typedef Score = Int; abstract Value<T>(T) from T to T {} function read(value:Value<Int>):Int return 40; function main():Int return read(1);",
				"typedef Score = Int; abstract Value<T>(T) from T to T {} function read(value:Value<Score>):Int return 40; function main():Int return read(1);",
				BodyPatch),
			sourceFixture("generic abstract constructor body",
				"abstract Value<T>(T) { public function new(value:T) { this = value; } } function main():Int { new Value<Int>(40); return 40; }",
				"abstract Value<T>(T) { public function new(value:T) { var changed = value; this = changed; } } function main():Int { new Value<Int>(40); return 40; }",
				BodyPatch),
			sourceFixture("abstract conversion removal",
				"abstract Value(Int) from Int to Int {} function read(value:Value):Int return value; function main():Int return read(40);",
				"abstract Value(Int) from Int {} function read(value:Value):Int return value; function main():Int return read(40);", RejectWith("E1003")),
			sourceFixture("generic constraint addition", "function consume<T>(value:T):Int return 40; function main():Int return consume(1);",
				"interface Readable { function read():Int; } function consume<T:Readable>(value:T):Int return 40; function main():Int return consume(1);",
				RejectWith("E1003")),
			sourceFixture("generic base declaration change",
				"class Base<T> {} class Other<T> {} class Editor extends Base<Int> {} function main():Int { return 40; }",
				"class Base<T> {} class Other<T> {} class Editor extends Other<Int> {} function main():Int { return 40; }",
				ReloadFor(ObjectLayoutChanged("Editor"))),
			sourceFixture("interface method addition",
				"interface Plugin { function read():Int; } class Editor implements Plugin { public function read():Int { return 40; } } function main():Int { return new Editor().read(); }",
				"interface Plugin { function read():Int; function reset():Void; } class Editor implements Plugin { public function read():Int { return 40; } public function reset():Void {} } function main():Int { return new Editor().read(); }",
				ReloadFor(InterfaceChanged("Plugin"))),
			sourceFixture("closure capture change",
				"function main():Int { var offset = 2; var more = 3; var f = (value:Int) -> { return value + offset; }; return f(38); }",
				"function main():Int { var offset = 2; var more = 3; var f = (value:Int) -> { return value + more; }; return f(39); }",
				ReloadFor(ClosureLayoutChanged("$lambda-env:main:main#0"))),
			sourceFixture("constructor removal", "class Editor { public function new():Void {} } function main():Int { return 40; }",
				"class Editor {} function main():Int { return 40; }", ReloadFor(FunctionRemoved("Editor.new"))),
			sourceFixture("function declaration order",
				"function first():Int { return 1; } function second():Int { return 2; } function main():Int { return 40; }",
				"function second():Int { return 2; } function first():Int { return 1; } function main():Int { return 40; }", BodyPatch),
			sourceFixture("function debug line relocation", "function helper():Int { return 1; } function main():Int { return 40; }",
				"function helper():Int { return 1; }\nfunction main():Int { return 40; }", BodyPatch),
			sourceFixture("enum case addition", "enum Result { Ok; } function main():Int { return 40; }",
				"enum Result { Ok; Error; } function main():Int { return 40; }", ReloadFor(EnumChanged("Result"))),
			sourceFixture("static field type", "class State { public static var value:Int; } function main():Int { return 40; }",
				"class State { public static var value:Float; } function main():Int { return 40; }", ReloadFor(GlobalLayoutChanged("State.value"))),
			sourceFixture("invalid return", "function main():Int { return 40; }", "function main():Int { return \"bad\"; }", RejectWith("E1003"))
		];
		for (fixture in sourceFixtures)
			assertSourceDecision(fixture);
		Sys.println('PASS: ${sourceFixtures.length} source ABI decision fixtures');
		assertCleanEquivalence();
	}

	static function assertReasonSchema(fixtures:Array<AbiFixture>):Void {
		// Reasons only the assembler gives, which no planner fixture produces.
		for (reason in [
			ObjectFieldTypeChanged("Editor.value"),
			ObjectFieldReserveExhausted("Editor"),
			ObjectMethodDispatchChanged("Editor.read")
		])
			if (!Type.enumEq(reason, AbiChangeSchema.decode(AbiChangeSchema.VERSION, AbiChangeSchema.encode(reason))))
				throw '$reason did not round trip';
		for (fixture in fixtures)
			switch fixture.expected {
				case Patch:
				case Reload(reason):
					if (!Type.enumEq(reason, AbiChangeSchema.decode(AbiChangeSchema.VERSION, AbiChangeSchema.encode(reason))))
						throw '${fixture.name}: structured ABI reason did not round trip';
			}
		try {
			AbiChangeSchema.decode(99, {code: "object_added", entityKind: "object", entityId: "Editor"});
			throw "ABI reason schema accepted an unknown version";
		} catch (error:String) {
			if (error.indexOf("Unsupported ABI change schema") < 0)
				throw error;
		}
		try {
			AbiChangeSchema.decode(AbiChangeSchema.VERSION, {code: "future_change", entityKind: "object", entityId: "Editor"});
			throw "ABI reason schema accepted an unknown code";
		} catch (error:String) {
			if (error.indexOf("Unknown ABI change code") < 0)
				throw error;
		}
	}

	static function fixture(name:String, previous:Null<RuntimeAbiDescriptor>, next:RuntimeAbiDescriptor, expected:ExpectedDecision,
			addsFunctions:Bool = false):AbiFixture
		return {
			name: name,
			previous: previous,
			next: next,
			expected: expected,
			addsFunctions: addsFunctions
		};

	static function abi(?functions:Map<String, String>, ?objects:Map<String, String>, ?interfaces:Map<String, String>, ?enums:Map<String, String>,
			?globals:Map<String, String>, ?positional:Map<String, String>):RuntimeAbiDescriptor
		return {
			functions: functions == null ? [] : functions,
			objects: objects == null ? [] : objects,
			interfaces: interfaces == null ? [] : interfaces,
			enums: enums == null ? [] : enums,
			globals: globals == null ? [] : globals,
			positional: positional == null ? [] : positional
		};

	static function assertDecision(fixture:AbiFixture):Void {
		var actual = PatchPlanner.plan(fixture.previous, fixture.next, fixture.addsFunctions, fixture.addsFunctions);
		switch [fixture.expected, actual] {
			case [Patch, Patch]:
			case [Reload(expected), ReloadDomain(reasons)] if (reasons.length == 1 && Type.enumEq(expected, reasons[0])):
			case [_, _]:
				throw '${fixture.name}: expected ${fixture.expected}, got $actual';
		}
	}

	static function sourceFixture(name:String, before:String, after:String, expected:SourceDecision):SourceFixture
		return {
			name: name,
			before: before,
			after: after,
			expected: expected
		};

	static function assertSourceDecision(fixture:SourceFixture):Void {
		var compiler = new Compiler();
		compiler.update("Main.hx", fixture.before);
		compiler.compile("Main");
		var baseline = compiler.exportIdentityState();
		compiler.update("Main.hx", fixture.after);
		try {
			var result = compiler.compile("Main");
			switch fixture.expected {
				case NoOp if (!result.requiresReload && result.changedFunctions.length == 0 && result.patchBytes == null):
				case BodyPatch if (!result.requiresReload && result.changedFunctions.length > 0 && result.patchBytes != null):
				case ReloadFor(reason) if (result.requiresReload
					&& result.patchBytes == null
					&& containsReason(result.reloadReasons, reason)):
				case _:
					throw '${fixture.name}: unexpected compiler artifact decision (${result.reloadReasons})';
			}
		} catch (error:CompileError) {
			switch fixture.expected {
				case RejectWith(code) if (error.diagnostic.code == code):
					if (compiler.exportIdentityState().compare(baseline) != 0)
						throw '${fixture.name}: rejected edit changed committed state';
				case _:
					throw error;
			}
		}
	}

	static function containsReason(reasons:Array<AbiChange>, expected:AbiChange):Bool {
		for (reason in reasons)
			if (Type.enumEq(reason, expected))
				return true;
		return false;
	}

	static function assertCleanEquivalence():Void {
		var before = "function value():Int { return 40; } function main():Int { return value(); }";
		var after = "function value():Int { return 42; } function main():Int { return value(); }";
		var incremental = new Compiler();
		incremental.update("Main.hx", before);
		incremental.compile("Main");
		incremental.update("Main.hx", after);
		var incrementalResult = incremental.compile("Main");
		var clean = new Compiler();
		clean.update("Main.hx", after);
		var cleanResult = clean.compile("Main");
		var incrementalAbi = RuntimeAbiCodec.encode(RuntimeAbi.describe(incrementalResult.ir));
		var cleanAbi = RuntimeAbiCodec.encode(RuntimeAbi.describe(cleanResult.ir));
		if (incrementalAbi.compare(cleanAbi) != 0)
			throw "Incremental and clean compilation produced different runtime ABI";
		for (name => cleanId in cleanResult.functionIds)
			if (incrementalResult.functionIds.get(name) != cleanId)
				throw 'Incremental and clean compilation assigned different stable ID to $name';
		Sys.println("PASS: incremental edit agrees with clean ABI and stable identities");
	}
}
