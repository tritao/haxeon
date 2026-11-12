import compiler.ir.Ir;
import compiler.backend.Backend.BackendTarget;
import compiler.backend.wasm.WasmLayout;
import compiler.backend.wasm.WasmModule;
import compiler.backend.wasm.WasmTypes;
import compiler.backend.wasm.WasmTypeIdPlan;
import compiler.backend.wasm.linear.WasmLinearContext;
import compiler.backend.wasm.linear.WasmLinearRuntime;

/** Finalization fills existing slots: appending an orphan duplicated the whole stringifier. */
@:access(compiler.ir.IrBuilder)
@:access(compiler.backend.wasm.gc.WasmGcModuleBuilder)
class WasmStringFinalizationMain {
	static function main():Void {
		checkSlots();
		checkSharedLinearFormatter();
		checkSharedGcFormatter();
		checkGcPayloadLayout();
		checkGcDescriptorWidths();
		checkGcDescriptorKeys();
		checkGcWideDescriptorExecution();
		checkReachableEnums();
		checkPrunedTagDeclarations();
		for (target in ["hl", "wasm32", "wasm-gc"])
			for (inlining in [false, true])
				checkExecution(target, inlining);
	}

	/** Adding constructors changes metadata, not the shared formatter's instruction count. */
	static function checkSharedLinearFormatter():Void {
		function instructionCount(cases:Int):Int {
			var program = new IrProgram("main"),
				constructors:Array<compiler.ir.Ir.IrEnumCase> = [];
			for (i in 0...cases)
				constructors.push({name: "Case" + i, params: [I32]});
			program.enums = [{name: "Sample", cases: constructors}];
			program.natives = [
				{
					name: "__std_string",
					library: "haxeon_runtime",
					symbol: "__std_string",
					arguments: [Dyn],
					result: Bytes
				}
			];
			var module = new WasmModule(), functions:Map<String, Int> = [], strings:Map<String, Int> = [], index = 8;
			module.runtimeTypeIds = WasmTypeIdPlan.forProgram(program);
			for (text in ["null", "Object", "true", "false", ",", ")"]) {
				strings.set(text, index);
				index += 8;
			}
			var allocator = module.addFunction(new WasmFunction("allocator", {parameters: [I32], results: [I32]}, [], [I32Const(0), Return]));
			var context = new WasmLinearContext(module, program, new WasmLayout(program), {target: Wasm32, debugNames: true}, {
				functions: functions,
				globals: [],
				rootGlobals: [],
				strings: strings,
				heapStart: 0,
				rootBase: 0,
				rootTop: 0,
				rootFrameTop: 0,
				rootLimit: 0,
				markStackTop: 0,
				heapState: 0,
				reflectionTable: 0,
				reflectionCount: 0,
				reflectionBytes: null
			});
			context.allocatorFunction = allocator;
			context.stringifiableEnums = ["Sample" => true];
			context.enumStringTable = 256;
			context.enumStringRows = 1;
			WasmLinearRuntime.register(context);
			WasmLinearRuntime.finalizeDynamicString(context);
			return module.functions[functions.get("__std_string")].body.length;
		}
		if (instructionCount(1) != instructionCount(100))
			throw "Enum constructors grew the shared Wasm32 formatter";
		Sys.println("PASS: enum constructors do not grow the shared Wasm32 formatter");
	}

	static function checkSharedGcFormatter():Void {
		function instructionCount(cases:Int, enums:Int):Int {
			var program = new IrProgram("main"),
				constructors:Array<compiler.ir.Ir.IrEnumCase> = [];
			for (i in 0...cases)
				constructors.push({name: "Case" + i, params: [I32]});
			program.enums = [for (i in 0...enums) {name: "Sample" + i, cases: constructors}];
			var selected:Map<String, Bool> = [];
			for (entry in program.enums)
				selected.set(entry.name, true);
			var plan = new compiler.backend.wasm.gc.WasmGcTypePlan(program),
				module = new WasmModule();
			var functions:Map<String, Int> = [
				"__std_string" => 0,
				"__haxeon_enum_string_name" => 1,
				"__haxeon_enum_string_concat" => 2
			];
			var context = new compiler.backend.wasm.gc.WasmGcContext(module, plan, functions, [], []);
			context.stringifiableEnums = selected;
			context.enumStringTable = {
				segment: 0,
				words: 1,
				names: cases,
				dataGlobal: 0,
				cacheGlobal: 1,
				dataTypeIndex: 0,
				cacheTypeIndex: 0,
				narrow: true
			};
			var next = 2;
			var representation = new compiler.backend.wasm.gc.WasmGcRepresentation(context).forFunction({
				allocateLocal: _ -> next++,
				exceptionTag: null,
				irFunction: null
			});
			return representation.stdStringBody(0, 1).length;
		}
		if (instructionCount(1, 1) != instructionCount(100, 1) || instructionCount(1, 1) != instructionCount(1, 100))
			throw "Enum constructors grew the shared Wasm GC formatter";
		Sys.println("PASS: enum types and constructors do not grow the shared Wasm GC formatter");
	}

	/** Formatter data types must not alter the recursive group that defines enum identity. */
	static function checkGcPayloadLayout():Void {
		var program = new IrProgram("main");
		program.enums = [
			{name: "Payload", cases: [{name: "None", params: []}, {name: "Item", params: [I32, F64, Dyn]}]}
		];
		var plan = new compiler.backend.wasm.gc.WasmGcTypePlan(program),
			module = new WasmModule();
		plan.addTo(module);
		function encodeGroup():haxe.io.Bytes {
			var isolated = new WasmModule();
			isolated.types.push(module.types[0]);
			return compiler.backend.wasm.WasmEncoder.encode(isolated);
		}
		var originalGroup = encodeGroup(), originalCount = module.types.length;
		var context = new compiler.backend.wasm.gc.WasmGcContext(module, plan, [], [], []);
		context.enumDeclarations = program.enums;
		context.stringifiableEnums = ["Payload" => true];
		var representation = new compiler.backend.wasm.gc.WasmGcRepresentation(context);
		compiler.backend.wasm.gc.WasmGcModuleBuilder.addGcEnumStringTable(module, plan, context, representation);
		if (originalGroup.compare(encodeGroup()) != 0 || module.types.length <= originalCount)
			throw "Enum stringification changed the Wasm GC recursive type group";
		switch module.typeAt(plan.enumConstructorType("Payload", 1)).composite {
			case Struct(fields) if (fields.length == 4):
			default:
				throw "Stringification changed the Wasm GC enum payload layout";
		}
		Sys.println("PASS: enum stringification preserves the Wasm GC recursive type group and payload fields");
	}

	/** The compact table must also support modules exceeding 16-bit offsets or table slots. */
	static function checkGcDescriptorWidths():Void {
		function make(name:String, matcher:Int):compiler.backend.wasm.gc.WasmGcEnumStringTable {
			var program = new IrProgram("main");
			program.enums = [{name: "E", cases: [{name: name, params: []}]}];
			return new compiler.backend.wasm.gc.WasmGcEnumStringTable(program, ["E" => true], program.enums, ["E" => [-1]], ["E" => matcher]);
		}
		var small = make("Short", 17),
			bigName = make(StringTools.lpad("X", "x", 70000), 17),
			bigSlot = make("Short", 70000);
		if (!small.narrow || bigName.narrow || bigSlot.narrow)
			throw "Wrong enum descriptor word width";
		if (small.bytes.getUInt16(8) != 17 || bigSlot.bytes.getInt32(16) != 70000)
			throw "Enum descriptor slot was truncated";
		Sys.println("PASS: enum descriptor slots and long names retain their full width");
	}

	/** Distinct logical tag types must not share a descriptor because their names contain separators. */
	static function checkGcDescriptorKeys():Void {
		var program = new IrProgram("main");
		program.enums = [
			{
				name: "Carrier",
				cases: [
					{name: "First", params: [EnumTag("A"), EnumTag("B")]},
					{name: "Second", params: [EnumTag("A;e:B")]}
				]
			}
		];
		var declarations = program.enums.concat([
			{name: "A", cases: [{name: "A1", params: []}]},
			{name: "B", cases: [{name: "B1", params: []}]},
			{name: "A;e:B", cases: [{name: "Combined", params: []}]}
		]);
		var table = new compiler.backend.wasm.gc.WasmGcEnumStringTable(program, ["Carrier" => true], declarations, ["Carrier" => [1, 2]], ["Carrier" => 0]);
		if (!table.narrow)
			throw "Expected compact descriptors";
		var casesAt = table.bytes.getUInt16(6 * 2),
			first = table.bytes.getUInt16((casesAt + 1) * 2),
			second = table.bytes.getUInt16((casesAt + 4) * 2);
		if (first == second)
			throw "Distinct enum tag descriptors were merged";
		Sys.println("PASS: enum tag descriptor keys distinguish separator-containing names");
	}

	/** Exercise the wide descriptor encoding in an actual GC module. */
	static function checkGcWideDescriptorExecution():Void {
		var name = StringTools.lpad("X", "x", 65536);
		var session = new compiler.Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		session.addStandardLibrarySourceRoot("stdlib");
		session.configure("enum-string-wide", "enum-string-wide", compiler.tools.CompilerDriver.targetDefines("wasm-gc"));
		session.update("Main.hx",
			'enum LongName { $name(v:Int); } function main():Int { var value:Dynamic = $name(7); return Std.string(value).length == 65539 ? 42 : 1; }');
		var program = session.compile("Main").ir;
		var bytes = new compiler.backend.wasm.WasmBackend().compile(program, {target: WasmGc, debugNames: false}).bytes;
		var script = 'const e=new WebAssembly.Instance(new WebAssembly.Module(require("fs").readFileSync(0))).exports;if(e.main()!==42)throw Error("wide descriptor");';
		var child = new sys.io.Process("node", ["-e", script]);
		child.stdin.write(bytes);
		child.stdin.close();
		var output = child.stdout.readAll().toString(),
			error = child.stderr.readAll().toString(),
			status = child.exitCode();
		child.close();
		if (status != 0)
			throw output + error;
		Sys.println("PASS: wide enum string descriptors execute on Wasm GC");
	}

	static function checkSlots():Void {
		var program = new IrProgram("main");
		program.natives = [
			{
				name: "__std_string",
				library: "haxeon_runtime",
				symbol: "__std_string",
				arguments: [Dyn],
				result: Bytes
			}
		];
		var module = new WasmModule(), functions:Map<String, Int> = [], strings:Map<String, Int> = [], index = 8;
		module.runtimeTypeIds = WasmTypeIdPlan.forProgram(program);
		for (text in ["null", "Object", "true", "false"]) {
			strings.set(text, index);
			index += 8;
		}
		var allocator = module.addFunction(new WasmFunction("allocator", {parameters: [I32], results: [I32]}, [], [I32Const(0), Return])),
			context = new WasmLinearContext(module, program, new WasmLayout(program), {target: Wasm32, debugNames: true}, {
				functions: functions,
				globals: [],
				rootGlobals: [],
				strings: strings,
				heapStart: 0,
				rootBase: 0,
				rootTop: 0,
				rootFrameTop: 0,
				rootLimit: 0,
				markStackTop: 0,
				heapState: 0,
				reflectionTable: 0,
				reflectionCount: 0,
				reflectionBytes: null
			});
		context.allocatorFunction = allocator;
		WasmLinearRuntime.register(context);
		var slot = functions.get("__std_string"),
			count = module.functions.length;
		if (slot == null)
			throw "Missing stringifier";
		for (_ in 0...2) {
			WasmLinearRuntime.finalizeDynamicString(context);
			if (module.functions.length != count || functions.get("__std_string") != slot)
				throw "String finalization appended a duplicate function or moved its slot";
		}
		for (name in ["__std_string", "__haxeon_i32_to_string", "__haxeon_i64_to_string"]) {
			var found = 0;
			for (fn in module.functions)
				if (fn.name == name)
					found++;
			if (found != 1)
				throw 'Expected one "$name", found $found';
		}
		Sys.println("PASS: dynamic string finalization preserves slots and emits one stringifier and one formatter per numeric kind");
	}

	static function checkReachableEnums():Void {
		var program = new IrProgram("main");
		program.enums = [
			{name: "Live", cases: [{name: "LiveCase", params: [I32]}]},
			{name: "Dead", cases: [{name: "DeadCase", params: [I32]}]},
			{name: "TypedOnly", cases: [{name: "TypedCase", params: [I32]}]}
		];
		function make(name:String, enumName:String):compiler.ir.IrFunction {
			var b = new compiler.ir.IrBuilder(),
				value = b.constInt(7),
				result = b.temporary(Enum(enumName));
			b.emit(MakeEnum(result, enumName, 0, [value]));
			if (enumName == "Live") {
				b.toDyn(result);
				var typedOnly = b.temporary(Enum("TypedOnly"));
				b.emit(MakeEnum(typedOnly, "TypedOnly", 0, [value]));
			}
			b.returnValue(b.constInt(42));
			return new compiler.ir.IrFunction(name, b.arguments, I32, b.blocks, Ordinary);
		}
		program.functions = [make("main", "Live"), make("unused", "Dead")];
		var reached:Map<String, Bool> = ["main" => true];
		var selected = compiler.backend.wasm.WasmModuleSupport.stringifiableEnums(program, reached);
		if (!selected.exists("Live") || selected.exists("Dead") || selected.exists("TypedOnly"))
			throw "enum formatting includes an unreachable or non-escaping enum";
		var exposed = new compiler.ir.IrBuilder();
		exposed.argument("hostValue", Dyn);
		exposed.returnValue(exposed.constInt(42));
		program.functions.push(new compiler.ir.IrFunction("entry", exposed.arguments, I32, exposed.blocks, Ordinary, null, false, Expose));
		reached.set("entry", true);
		if (!compiler.backend.wasm.WasmModuleSupport.stringifiableEnums(program, reached).exists("Dead"))
			throw "an exposed Dynamic parameter must preserve possible enum inputs";
		Sys.println("PASS: enum formatting follows reachable escapes and host inputs");
	}

	static function checkPrunedTagDeclarations():Void {
		var program = new IrProgram("main");
		program.enums = [
			{name: "TagOnly", cases: [{name: "One", params: []}, {name: "Two", params: []}]},
			{name: "Payload", cases: [{name: "With", params: [EnumTag("TagOnly")]}]}
		];
		program.natives = [
			{
				name: "__std_string",
				library: "haxeon_runtime",
				symbol: "__std_string",
				arguments: [Dyn],
				result: Bytes
			}
		];
		var b = new compiler.ir.IrBuilder(),
			tag = b.constNull(EnumTag("TagOnly")),
			payload = b.temporary(Enum("Payload"));
		b.emit(MakeEnum(payload, "Payload", 0, [tag]));
		b.call("__std_string", [b.toDyn(payload)], Bytes);
		b.returnValue(b.constInt(42));
		program.functions = [new compiler.ir.IrFunction("main", b.arguments, I32, b.blocks, Ordinary)];
		if (Lambda.exists(compiler.ir.IrEnumRuntimeTypes.physical(program).enums, entry -> entry.name == "TagOnly"))
			throw "the test requires a tag-only enum with no physical descriptor";
		for (target in ([Wasm32, WasmGc] : Array<BackendTarget>)) {
			var bytes = new compiler.backend.wasm.WasmBackend().compile(program, {target: target, debugNames: true, developmentMetadata: false}).bytes;
			if (!containsBytes(bytes, "One"))
				throw 'missing logical tag name for $target';
		}
		Sys.println("PASS: release stringification keeps tag names without a boxed descriptor");
	}

	static function containsBytes(bytes:haxe.io.Bytes, text:String):Bool {
		var needle = haxe.io.Bytes.ofString(text);
		for (offset in 0...(bytes.length - needle.length + 1)) {
			var matches = true;
			for (index in 0...needle.length)
				if (bytes.get(offset + index) != needle.get(index)) {
					matches = false;
					break;
				}
			if (matches)
				return true;
		}
		return false;
	}

	static function checkExecution(target:String, inlining:Bool):Void {
		var session = new compiler.Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		session.addStandardLibrarySourceRoot("stdlib");
		session.configure("string-finalization-" + target + inlining, "string-finalization",
			compiler.tools.CompilerDriver.targetDefines(target).concat(["haxeon-inline=" + (inlining ? 1 : 0)]));
		session.update("Main.hx",
			'enum Tone { Dark; Light; Shade(value:Int); } enum Unused { NeverSeen(value:Int); } '
			+ 'class Label { public function new() {} public function toString():String return "label"; } '
			+ 'function main():Int { var number:Dynamic=17, tone:Dynamic=Light, payload:Dynamic=Shade(7), label:Dynamic=new Label(); '
			+ 'return Std.string(number)=="17" && Std.string(tone)=="Light" && Std.string(payload)=="Shade(7)" && Std.string(label)=="label" '
			+ '&& Std.string(true)=="true" && Std.string(null)=="null" ? 42 : 1; }');
		var program = session.compile("Main").ir;
		var binary = target == "hl" ? new compiler.backend.hl.HlBackend().compile(program, {target: HashLink, debugNames: true})
			.bytes : new compiler.backend.wasm.WasmBackend().compile(program, {target: target == "wasm32" ? Wasm32 : WasmGc, debugNames: true}).bytes;
		if (target != "hl" && containsBytes(binary, "NeverSeen("))
			throw target + " emitted formatting for an unreachable enum";
		var temp = Sys.getEnv("TMPDIR");
		if (temp == null)
			temp = "/tmp";
		var path = temp + "/string-finalization-" + target + inlining + "-" + Std.random(0x7fffffff) + (target == "hl" ? ".hl" : ".wasm");
		sys.io.File.saveBytes(path, binary);
		try {
			var script = 'const e=new WebAssembly.Instance(new WebAssembly.Module(require("fs").readFileSync(process.argv[1]))).exports;'
				+ 'if(e.main()!==42)throw Error("dynamic stringification");';
			var child = new sys.io.Process(target == "hl" ? "scripts/hl" : "node", target == "hl" ? [path] : ["-e", script, path]);
			var output = child.stdout.readAll().toString(),
				error = child.stderr.readAll().toString(),
				status = child.exitCode();
			child.close();
			if (status != (target == "hl" ? 42 : 0))
				throw target + " inline=" + inlining + ": " + output + error;
		} catch (error:Dynamic) {
			sys.FileSystem.deleteFile(path);
			throw error;
		}
		sys.FileSystem.deleteFile(path);
		Sys.println("PASS: dynamic stringification " + target + " inline=" + inlining);
	}
}
