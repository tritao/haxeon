import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrInlineEnumCaseAccess;
import compiler.ir.IrInlineEnumLayout;
import compiler.ir.IrObjectTable;
import compiler.ir.IrValueLaneLayout.IrValueLaneTarget;
import compiler.types.typing.EnumEqualityGenerator;

/** Generated equality participates in the ordinary value ABI, including genuine escape round trips. */
@:access(compiler.ir.IrBuilder)
class InlineEnumEqualityAbiMain {
	static function get(builder:IrBuilder, name:String, type:IrType):IrValue {
		var value = builder.temporary(type); builder.emit(GlobalGet(value, name)); return value;
	}
	static function set(builder:IrBuilder, name:String, value:IrValue):Void builder.emit(GlobalSet(name, value));

	static function main():Void {
		for (target in ([HashLink, Wasm32, WasmGc]:Array<IrValueLaneTarget>))
			for (inlineEnabled in [false, true]) check(target, inlineEnabled);
		Sys.println("PASS: inline enum equality uses scalar/reference arguments; only genuine Dynamic boxes allocate");
	}

	static function check(target:IrValueLaneTarget, inlineEnabled:Bool):Void {
		var owner:IrObject = {name:"EqualityOwner", isValue:false, base:null, interfaces:[], methods:[], fields:[{name:"id", type:I32}]},
			declaration:IrEnum = {name:"EqualityValue", cases:[{name:"Empty", params:[]}, {name:"Code", params:[I32, Obj(owner.name)]}]},
			planner = new IrInlineEnumLayout([declaration], [owner], target == HashLink ? 64 : 32, target), shape = planner.shape(declaration.name),
			objects = [owner].concat(planner.generatedObjects()), table = IrObjectTable.of([for (object in objects) object.name => object]),
			access = new IrInlineEnumCaseAccess(shape, table), storage:IrType = Obj(shape.valueObject.name),
			logical = compiler.types.Type.CompilerType.TInstance(compiler.types.Type.NominalKind.Enum, declaration.name, []),
			equality = EnumEqualityGenerator.equalsName(logical), reflective = EnumEqualityGenerator.reflectiveName(logical),
			tagName = IrInlineEnumCaseAccess.HELPER_PREFIX + "equality-tag", numberName = IrInlineEnumCaseAccess.HELPER_PREFIX + "equality-number",
			ownerName = IrInlineEnumCaseAccess.HELPER_PREFIX + "equality-owner";
		var program = new IrProgram("main");
		program.objects = objects;
		program.enums = [{name:declaration.name, cases:declaration.cases, isRecursive:false, inlineStorage:shape.valueObject.name}];
		program.staticFields = [for (name in ["first", "same", "different", "empty", "nil"]) {name:name, type:storage}];
		program.natives = compiler.ir.IrInlineEnumWordAccess.natives();
		for (field in ["tag", "number", "owner"]) {
			var b = new IrBuilder(), value = b.argument("value", storage), result = switch field {
				case "tag": b.fieldGet(value, "tag", I32);
				case "number": access.field(b, value, 1, 0);
				default: access.field(b, value, 1, 1);
			};
			b.returnValue(result);
			program.functions.push(new IrFunction(field == "tag" ? tagName : field == "number" ? numberName : ownerName,
				b.arguments, result.type, b.blocks, compiler.Provides.Serves(compiler.ir.TypeKey.of(Obj(shape.valueObject.name)),
					compiler.Provides.ProviderOperation.detailed(compiler.Provides.ProviderOperation.InlineEnumHelper, field)), []));
		}
		for (name in [equality, reflective]) {
			var b = new IrBuilder(), a = b.argument("first", storage), z = b.argument("second", storage),
				left = b.call(tagName, [a], I32), right = b.call(tagName, [z], I32), same = b.createBlock(), different = b.createBlock(),
				payload = b.createBlock(), noPayload = b.createBlock(), owners = b.createBlock();
			b.branch(b.equal(left, right), same, different);
			b.select(different); b.returnValue(b.constBool(false));
			b.select(same); b.branch(b.equal(left, b.constInt(2)), payload, noPayload);
			b.select(noPayload); b.returnValue(b.constBool(true));
			b.select(payload);
			b.branch(b.equal(b.call(numberName, [a], I32), b.call(numberName, [z], I32)), owners, different);
			b.select(owners); b.returnValue(b.equal(b.call(ownerName, [a], Obj(owner.name)), b.call(ownerName, [z], Obj(owner.name))));
			program.functions.push(new IrFunction(name, b.arguments, Bool, b.blocks,
				compiler.Provides.Serves(compiler.ir.TypeKey.of(Enum(declaration.name)),
					name == equality ? compiler.Provides.ProviderOperation.Equals : compiler.Provides.ProviderOperation.ReflectEquals), []));
		}
		var prepare = new IrBuilder(), reference = prepare.newObject(owner.name);
		prepare.fieldSet(reference, "id", prepare.constInt(2));
		set(prepare, "first", access.construct(prepare, 1, [prepare.constInt(40), reference]));
		set(prepare, "same", access.construct(prepare, 1, [prepare.constInt(40), reference]));
		set(prepare, "different", access.construct(prepare, 1, [prepare.constInt(41), reference]));
		set(prepare, "empty", access.construct(prepare, 0, []));
		set(prepare, "nil", access.nullValue(prepare));
		prepare.returnValue(prepare.constVoid());
		program.functions.push(new IrFunction("prepare", prepare.arguments, Void, prepare.blocks, None, [], null, false, Expose));
		for (dynamicEscape in [false, true]) {
			var b = new IrBuilder(), count = b.argument("count", I32), initial = b.currentBlock().id,
				header = b.createBlock(), body = b.createBlock(), done = b.createBlock(), failure = b.createBlock(),
				iterations:Array<IrPhiInput> = [{block:initial, value:b.constInt(0)}], sums:Array<IrPhiInput> = [{block:initial, value:b.constInt(0)}];
			b.jump(header); b.select(header);
			var index = b.phi(I32, iterations), total = b.phi(I32, sums);
			b.branch(b.less(index, count), body, done); b.select(body);
			var first = get(b, "first", storage), same = get(b, "same", storage);
			if (dynamicEscape) {
				first = b.call(compiler.ir.IrInlineEnumEscapes.unboxName(declaration.name),
					[b.call(compiler.ir.IrInlineEnumEscapes.boxName(declaration.name), [first], Dyn)], storage);
				same = b.call(compiler.ir.IrInlineEnumEscapes.unboxName(declaration.name),
					[b.call(compiler.ir.IrInlineEnumEscapes.boxName(declaration.name), [same], Dyn)], storage);
			}
			var ownerAlive = b.createBlock();
			b.branch(b.equal(b.fieldGet(b.call(ownerName, [first], Obj(owner.name)), "id", I32), b.constInt(2)), ownerAlive, failure);
			b.select(ownerAlive);
			for (name in [equality, reflective]) {
				var matched = b.createBlock(), rejected = b.createBlock(), nulls = b.createBlock(), empty = b.createBlock(), next = b.createBlock();
				b.branch(b.call(name, [first, same], Bool), matched, failure); b.select(matched);
				b.branch(b.call(name, [first, get(b, "different", storage)], Bool), failure, rejected); b.select(rejected);
				b.branch(b.call(name, [get(b, "nil", storage), get(b, "nil", storage)], Bool), nulls, failure); b.select(nulls);
				b.branch(b.call(name, [get(b, "empty", storage), get(b, "empty", storage)], Bool), empty, failure); b.select(empty);
				b.branch(b.call(name, [get(b, "nil", storage), get(b, "empty", storage)], Bool), failure, next); b.select(next);
			}
			iterations.push({block:b.currentBlock().id, value:b.add(index, b.constInt(1))});
			sums.push({block:b.currentBlock().id, value:b.add(total, b.constInt(42))}); b.jump(header);
			b.select(done); b.returnValue(total); b.select(failure); b.returnValue(b.constInt(-1));
			program.functions.push(new IrFunction(dynamicEscape ? "dynamicCensus" : "typedCensus", b.arguments, I32, b.blocks, None, [], null, false, Expose));
		}
		var main = new IrBuilder(); main.returnValue(main.constInt(42));
		program.functions.push(new IrFunction("main", main.arguments, I32, main.blocks, None, []));
		program.functions = program.functions.concat(compiler.ir.IrInlineEnumEscapes.functions(program.enums, table, planner));
		compiler.ir.IrVerifier.verify(program);
		compiler.ir.IrValuePhiScalarization.rewrite(program);
		compiler.ir.IrScalarArguments.rewrite(program, target != HashLink);
		program.functions = [for (fn in program.functions) compiler.ir.IrScalarReplacement.rewrite(fn, table, false, target == HashLink)];
		compiler.ir.IrInliner.run(program, new compiler.ir.IrInliner.IrInlineCache(), target == HashLink ? compiler.ir.TargetProfile.hashLink : compiler.ir.TargetProfile.wasm, inlineEnabled);
		compiler.ir.IrVerifier.verify(program);
		run(program, target, inlineEnabled);
	}

	static function run(program:IrProgram, target:IrValueLaneTarget, inlineEnabled:Bool):Void {
		var root = Sys.getEnv("TMPDIR"); if (root == null || root == "") root = "/tmp";
		var stem = root + "/inline-enum-equality-" + Std.random(0x7fffffff), module = stem + (target == HashLink ? ".hl" : ".wasm"),
			captures:Array<{path:String, count:Int, dynamicEscape:Bool}> = [];
		if (target == HashLink) {
			var entry = new IrBuilder(), failure = entry.createBlock(), success = entry.createBlock();
			entry.call("prepare", [], Void);
			program.natives = program.natives.concat([
				{name:"major", library:"std", symbol:"gc_major", arguments:[], result:Void},
				{name:"censusStart", library:"std", symbol:"gc_census_start", arguments:[I32], result:Void},
				{name:"censusStop", library:"std", symbol:"gc_census_stop", arguments:[], result:Void},
				{name:"censusReset", library:"std", symbol:"gc_census_reset", arguments:[], result:Void},
				{name:"censusDump", library:"haxeon_runtime", symbol:"__gc_census_dump", arguments:[Bytes], result:Void},
				{name:"exit", library:"std", symbol:"sys_exit", arguments:[I32], result:Void}
			]);
			entry.call("major", [], Void);
			for (_ in 0...256) {
				var garbage = entry.newObject("EqualityOwner"); entry.fieldSet(garbage, "id", entry.constInt(99));
			}
			entry.call("major", [], Void);
			for (dynamicEscape in [false, true]) for (count in [8, 1024]) {
				var path = stem + "-" + dynamicEscape + "-" + count + ".json"; captures.push({path:path, count:count, dynamicEscape:dynamicEscape});
				entry.call("censusReset", [], Void); entry.call("censusStart", [entry.constInt(0)], Void);
				var result = entry.call(dynamicEscape ? "dynamicCensus" : "typedCensus", [entry.constInt(count)], I32);
				entry.call("censusStop", [], Void); entry.call("censusDump", [entry.constString(path)], Void);
				var next = entry.createBlock(); entry.branch(entry.equal(result, entry.constInt(42 * count)), next, failure); entry.select(next);
			}
			entry.jump(success); entry.select(success); entry.call("exit", [entry.constInt(42)], Void); entry.returnValue(entry.constVoid());
			entry.select(failure); entry.call("exit", [entry.constInt(1)], Void); entry.returnValue(entry.constVoid());
			program.functions.push(new IrFunction("entry", entry.arguments, Void, entry.blocks, None, [])); program.entryPoint = "entry";
		}
		var backendTarget:compiler.backend.Backend.BackendTarget = target == HashLink ? HashLink : target == Wasm32 ? Wasm32 : WasmGc,
			bytes = target == HashLink ? new compiler.backend.hl.HlBackend().compile(program, {target:backendTarget, debugNames:true}).bytes
				: new compiler.backend.wasm.WasmBackend().compile(program, {target:backendTarget, debugNames:true,
					wasmGcAllocationCount:target == WasmGc, wasmMemoryStats:target == Wasm32, wasmGcStress:target == Wasm32}).bytes;
		sys.io.File.saveBytes(module, bytes);
		try {
			var js = 'const e=new WebAssembly.Instance(new WebAssembly.Module(require("fs").readFileSync(process.argv[1]))).exports; e.prepare(); '
				+ 'const c=e.__allocation_count||e["haxeon.memory.allocation_count"]; for(const n of [8,1024]) for(const dynamic of [false,true]) {'
				+ 'const before=c(),result=e[dynamic?"dynamicCensus":"typedCensus"](n),count=c()-before; '
				+ 'if(result!==42*n||count!==(dynamic?2*n:0))throw Error(JSON.stringify({n,dynamic,result,count})); }';
			var process = new sys.io.Process(target == HashLink ? Sys.getEnv("HAXEON_HASHLINK_DIR") + "/hl" : "node", target == HashLink ? [module] : ["-e", js, module]),
				error = process.stderr.readAll().toString(), output = process.stdout.readAll().toString(), status = process.exitCode(); process.close();
			if (status != (target == HashLink ? 42 : 0)) throw '$target inline=$inlineEnabled equality ABI failed ($status): $error $output';
			for (capture in captures) {
				var census:Dynamic = haxe.Json.parse(sys.io.File.getContent(capture.path));
				if (census.allocations != (capture.dynamicEscape ? 2 * capture.count : 0))
					throw 'Unexpected $target equality allocations: ${census.allocations}, dynamic=${capture.dynamicEscape}, count=${capture.count}';
			}
			Sys.println('PASS: $target inline=$inlineEnabled equality typed=0 boxes, Dynamic=2 boxes/call at 8/1024 calls');
		} catch (error:Dynamic) {
			for (capture in captures) if (sys.FileSystem.exists(capture.path)) sys.FileSystem.deleteFile(capture.path);
			if (sys.FileSystem.exists(module)) sys.FileSystem.deleteFile(module);
			throw error;
		}
		for (capture in captures) sys.FileSystem.deleteFile(capture.path);
		sys.FileSystem.deleteFile(module);
	}
}
