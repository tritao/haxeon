import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrEnumTagStorage;
import compiler.ir.IrFunction;
import compiler.ir.IrScalarWordBits;
import compiler.ir.IrVerifier;
import compiler.backend.Backend.BackendTarget;

/** The tag retains nominal identity while its physical carrier is exactly I32. */
@:access(compiler.ir.IrBuilder)
class EnumTagStorageMain {
	static function declaration():IrEnum
		return {name: "Mode", cases: [{name: "Off", params: []}, {name: "On", params: []}]};

	static function program():IrProgram {
		var b = new IrBuilder(),
			first = b.temporary(EnumTag("Mode")),
			second = b.temporary(EnumTag("Mode"));
		b.emit(MakeEnum(first, "Mode", 0, []));
		b.emit(MakeEnum(second, "Mode", 1, []));
		var index = b.temporary(I32);
		b.emit(EnumIndex(index, second));
		var checks = [
			b.equal(index, b.constInt(1)),
			b.equal(first, first),
			b.equal(b.equal(first, second), b.constBool(false)),
			b.equal(b.call(IrScalarWordBits.PACK, [first], I32), b.constInt(1)),
			b.equal(b.call(IrScalarWordBits.PACK, [b.constNull(EnumTag("Mode"))], I32), b.constInt(0))
		];
		for (value in [first, second, b.constNull(EnumTag("Mode"))]) {
			var boxed = b.call(IrEnumTagStorage.boxName("Mode"), [value], Dyn),
				roundtrip = b.call(IrEnumTagStorage.unboxName("Mode"), [boxed], EnumTag("Mode"));
			checks.push(b.equal(value, roundtrip));
		}
		var failed = b.createBlock();
		for (check in checks) {
			var next = b.createBlock();
			b.branch(check, next, failed);
			b.select(next);
		}
		b.returnValue(b.constInt(42));
		b.select(failed);
		b.returnValue(b.constInt(1));
		var p = new IrProgram("main");
		p.enums = [declaration()];
		p.natives = [
			{
				name: "__std_is_exact_type",
				library: "haxeon_runtime",
				symbol: "__std_is_exact_type",
				arguments: [Dyn, TypeRef],
				result: Bool
			}
		];
		p.functions = [new IrFunction("main", b.arguments, I32, b.blocks, Ordinary)].concat(IrEnumTagStorage.adapters(declaration()));
		return p;
	}

	static function arrayProgram(target:compiler.ir.IrValueLaneLayout.IrValueLaneTarget):IrProgram {
		var p = program(), b = new IrBuilder(), array = b.call("__array_alloc_ref", [b.constInt(2)], Array(EnumTag("Mode"))),
			value = b.temporary(EnumTag("Mode"));
		b.emit(MakeEnum(value, "Mode", 1, []));
		b.emit(ArraySet(array, b.constInt(0), value));
		b.emit(ArraySet(array, b.constInt(1), b.constNull(EnumTag("Mode"))));
		var loaded = b.temporary(EnumTag("Mode")),
			nil = b.temporary(EnumTag("Mode"));
		b.emit(ArrayGet(loaded, array, b.constInt(0)));
		b.emit(ArrayGet(nil, array, b.constInt(1)));
		var owner = b.newObject("Holder");
		b.fieldSet(owner, "mode", value);
		b.fieldSet(owner, "number", b.constInt(42));
		var inField = b.fieldGet(owner, "mode", EnumTag("Mode"));
		if (target == HashLink) {
			p.natives.push({name: "nativeObjectSize", library: "std", symbol: "type_data_size", arguments: [TypeRef], result: I32});
			var sized = b.createBlock(), wrongSize = b.createBlock();
			b.branch(b.equal(b.call("nativeObjectSize", [b.typeValue(Obj("Holder"))], I32), b.constInt(16)), sized, wrongSize);
			b.select(wrongSize);
			b.returnValue(b.constInt(3));
			b.select(sized);
		}
		var fieldOkay = b.createBlock(), fieldBad = b.createBlock();
		b.branch(b.equal(inField, loaded), fieldOkay, fieldBad);
		b.select(fieldBad);
		b.returnValue(b.constInt(2));
		b.select(fieldOkay);
		p.objects.push({
			name: "Holder",
			isValue: false,
			base: null,
			interfaces: [],
			methods: [],
			fields: [{name: "mode", type: EnumTag("Mode"), scalarStorage: {size: 4, signed: true}}, {name: "number", type: I32}]
		});
		var bad = b.createBlock(), next = b.createBlock();
		b.branch(b.equal(loaded, value), next, bad);
		b.select(next);
		var good = b.createBlock();
		b.branch(b.equal(nil, b.constNull(EnumTag("Mode"))), good, bad);
		b.select(good);
		b.returnValue(b.constInt(42));
		b.select(bad);
		b.returnValue(b.constInt(1));
		p.functions[0] = new IrFunction("main", b.arguments, I32, b.blocks, Ordinary);
		p.natives.push({
			name: "__array_alloc_ref",
			library: "haxeon_runtime",
			symbol: "__array_alloc_ref",
			arguments: [I32],
			result: Array(EnumTag("Mode"))
		});
		compiler.ir.IrValueArrayProgramRewrite.rewrite(p, EnumTag("Mode"), target == HashLink ? 64 : 32, target);
		IrVerifier.verifyValueArraysLowered(p);
		return p;
	}

	/** Model a native that receives/returns the nominal boxed ABI, independently of typed source storage. */
	static function nativeProgram():IrProgram {
		var p = new IrProgram("main"),
			b = new IrBuilder(),
			value = b.temporary(Enum("Mode"));
		p.enums = [declaration()];
		p.natives = [
			{
				name: "nativeRoundtrip",
				library: "test",
				symbol: "roundtrip",
				arguments: [Enum("Mode")],
				result: Enum("Mode")
			}
		];
		b.emit(MakeEnum(value, "Mode", 1, []));
		var returned = b.call("nativeRoundtrip", [value], Enum("Mode")),
			index = b.temporary(I32);
		b.emit(EnumIndex(index, returned));
		b.returnValue(b.add(index, b.constInt(41)));
		p.functions = [new IrFunction("main", b.arguments, I32, b.blocks, Ordinary)];
		compiler.ir.IrEnumTagLowering.run(p);
		compiler.ir.IrEnumTagLowering.escapes(p);
		// Supply a deterministic boxed-ABI stub so the same wrapper executes on every target.
		p.natives = [for (native in p.natives) if (native.name != "nativeRoundtrip") native];
		var stub = new IrBuilder(),
			input = stub.argument("input", Enum("Mode"));
		stub.returnValue(input);
		p.functions.push(new IrFunction("nativeRoundtrip", stub.arguments, Enum("Mode"), stub.blocks, Ordinary));
		return p;
	}

	static function reject(type:IrType, expected:String):Void {
		var p = program(), b = new IrBuilder();
		b.argument("bad", type);
		b.returnValue(b.constInt(42));
		p.functions.push(new IrFunction("bad", b.arguments, I32, b.blocks, Ordinary));
		var message = "";
		try
			IrVerifier.verify(p)
		catch (error:Dynamic)
			message = Std.string(error);
		if (message.indexOf(expected) < 0)
			throw 'Expected $expected, got $message';
	}

	static function rejected(p:IrProgram, expected:String):Void {
		var message = "";
		try
			IrVerifier.verify(p)
		catch (error:Dynamic)
			message = Std.string(error);
		if (message.indexOf(expected) < 0)
			throw 'Expected $expected, got $message';
	}

	static function main():Void {
		var logical = new IrProgram("logical"),
			body = new IrBuilder(),
			nominal = body.temporary(Enum("Mode"));
		logical.enums = [declaration()];
		body.emit(MakeEnum(nominal, "Mode", 1, []));
		var roundtrip = body.safeCast(body.toDyn(nominal), Enum("Mode")),
			logicalIndex = body.temporary(I32);
		body.emit(EnumIndex(logicalIndex, roundtrip));
		body.returnValue(body.add(logicalIndex, body.constInt(41)));
		logical.functions = [new IrFunction("logical", body.arguments, I32, body.blocks, Ordinary)];
		compiler.ir.IrEnumTagLowering.run(logical);
		compiler.ir.IrEnumTagLowering.escapes(logical);
		IrVerifier.verify(logical);
		if (new compiler.ir.IrInterpreter(logical).run() != 42)
			throw "Logical tag lowering failed";
		if (IrVerifier.sameType(EnumTag("Mode"), I32) || IrVerifier.sameType(EnumTag("Mode"), EnumTag("Other")))
			throw "Tag identity erased";
		var encoded = compiler.ir.codec.IrTypeCodec.encode(Function([Array(EnumTag("Mode"))], EnumTag("Mode")));
		if (!IrVerifier.sameType(compiler.ir.codec.IrTypeCodec.decode(encoded), Function([Array(EnumTag("Mode"))], EnumTag("Mode"))))
			throw "Tag codec lost identity";
		var nullCheck = program(), checkBody = new IrBuilder();
		checkBody.call(compiler.ir.IrReceiverCheck.NAME, [checkBody.constNull(EnumTag("Mode"))], Void);
		checkBody.returnValue(checkBody.constInt(42));
		nullCheck.functions.push(new IrFunction("nullCheck", checkBody.arguments, I32, checkBody.blocks, Ordinary));
		IrVerifier.verify(nullCheck);
		var nullMessage = "";
		try
			new compiler.ir.IrInterpreter(nullCheck).run("nullCheck")
		catch (error:Dynamic)
			nullMessage = Std.string(error);
		if (nullMessage.indexOf("Null access") < 0)
			throw "Interpreter accepted a tag-zero receiver";
		var referenceCheck = program(), referenceBody = new IrBuilder();
		referenceCheck.objects.push({name: "Reference", isValue: false, base: null, interfaces: [], methods: [], fields: []});
		referenceBody.call(compiler.ir.IrReceiverCheck.NAME, [referenceBody.newObject("Reference")], Void);
		referenceBody.returnValue(referenceBody.constInt(42));
		referenceCheck.functions.push(new IrFunction("referenceCheck", referenceBody.arguments, I32, referenceBody.blocks, Ordinary));
		IrVerifier.verify(referenceCheck);
		if (new compiler.ir.IrInterpreter(referenceCheck).run("referenceCheck") != 42)
			throw "Interpreter reinterpreted a reference receiver as a numeric tag";
		for (size in [0, 1, 2, 8]) {
			var malformed = program();
			malformed.objects.push({name: "WrongTagWidth", isValue: false, base: null, interfaces: [], methods: [],
				fields: [{name: "mode", type: EnumTag("Mode"), scalarStorage: {size: size, signed: true}}]});
			rejected(malformed, "Invalid scalar storage");
		}
		reject(EnumTag("Missing"), "requires a payload-free enum");
		for (operation in 0...3) {
			var malformed = program(),
				access = new IrBuilder(),
				array = access.argument("array", Array(EnumTag("Mode"))),
				index = access.constInt(0);
			switch operation {
				case 0:
					access.emit(ArrayGet(access.temporary(EnumTag("Mode")), array, index));
				case 1:
					access.emit(ArraySet(array, index, access.constNull(EnumTag("Mode"))));
				case 2:
					access.emit(IteratorNew(access.temporary(Iterator(EnumTag("Mode"))), array));
			}
			access.returnValue(access.constInt(42));
			malformed.functions.push(new IrFunction("badLaneAccess", access.arguments, I32, access.blocks, Ordinary));
			var message = "";
			try
				IrVerifier.verifyValueArraysLowered(malformed)
			catch (error:Dynamic)
				message = Std.string(error);
			if (message.indexOf("ordinary array operation on inline value lanes") < 0)
				throw "Unlowered tag array operation was accepted";
		}
		reject(Nullable(EnumTag("Mode")), "nullability must use tag zero");
		var badPayload = program();
		badPayload.enums[0].cases[0].params.push(I32);
		rejected(badPayload, "requires a payload-free enum");
		var escape = program(),
			escaped = new IrBuilder(),
			tag = escaped.argument("value", EnumTag("Mode"));
		escaped.returnValue(escaped.toDyn(tag));
		escape.functions.push(new IrFunction("badEscape", escaped.arguments, Dyn, escaped.blocks, Ordinary));
		rejected(escape, "requires a box adapter");
		var castProgram = program(),
			caster = new IrBuilder(),
			input = caster.argument("value", Dyn);
		caster.returnValue(caster.safeCast(input, EnumTag("Mode")));
		castProgram.functions.push(new IrFunction("badCast", caster.arguments, EnumTag("Mode"), caster.blocks, Ordinary));
		rejected(castProgram, "requires an unbox adapter");
		for (target in [HashLink, Wasm32, WasmGc])
			for (inlineEnabled in [false, true])
				for (variant in 0...3) {
					var arrays = variant == 1;
					var laneTarget:compiler.ir.IrValueLaneLayout.IrValueLaneTarget = switch target {
						case HashLink: HashLink;
						case Wasm32: Wasm32;
						case WasmGc: WasmGc;
						case Wasm64: throw "Unsupported target";
					};
					var p = arrays ? arrayProgram(laneTarget) : variant == 2 ? nativeProgram() : program();
					p = compiler.ir.codec.CanonicalIrCodec.decode(compiler.ir.codec.CanonicalIrCodec.encode(p));
					compiler.ir.IrInliner.run(p, new compiler.ir.IrInliner.IrInlineCache(),
						target == HashLink ? compiler.ir.TargetProfile.hashLink : compiler.ir.TargetProfile.wasm, inlineEnabled);
					IrVerifier.verify(p);
					if (!arrays && new compiler.ir.IrInterpreter(p).run() != 42)
						throw "Interpreter tag roundtrip failed";
					var laneTarget:compiler.ir.IrValueLaneLayout.IrValueLaneTarget = switch target {
						case HashLink: HashLink;
						case Wasm32: Wasm32;
						case WasmGc: WasmGc;
						case Wasm64: throw "Unsupported target";
					};
					var shape = new compiler.ir.IrValueLaneLayout(compiler.ir.IrObjectTable.of([]), target == HashLink ? 64 : 32,
						laneTarget).shape(EnumTag("Mode"));
					if (shape.scalarStrideBits != 32 || shape.references != 0 || shape.slots.length != 1 || shape.slots[0].isReference)
						throw "Tag is not a four-byte scalar lane";
					var root = Sys.getEnv("TMPDIR");
					if (root == null)
						root = "/tmp";
					var path = root + '/enum-tag-$target-$inlineEnabled-' + Std.random(0x7fffffff) + (target == HashLink ? ".hl" : ".wasm");
					try {
						if (target == HashLink) {
							var entry = new IrBuilder();
							entry.call("exit", [entry.call("main", [], I32)], Void);
							entry.returnValue(entry.constVoid());
							p.functions.push(new IrFunction("entry", entry.arguments, Void, entry.blocks, Ordinary));
							p.entryPoint = "entry";
							p.natives.push({
								name: "exit",
								library: "std",
								symbol: "sys_exit",
								arguments: [I32],
								result: Void
							});
						}
						var bytes = target == HashLink ? new compiler.backend.hl.HlBackend().compile(p, {target: target, debugNames: true})
							.bytes : new compiler.backend.wasm.WasmBackend().compile(p, {
								target: target,
								debugNames: true,
								wasmGcAllocationCount: target == WasmGc,
								wasmMemoryStats: target == Wasm32
							}).bytes;
						sys.io.File.saveBytes(path, bytes);
						var vm = Sys.getEnv("HAXEON_HASHLINK_DIR"),
							command = target == HashLink ? (vm == null ? "scripts/hl" : vm + "/hl") : "node";
						var script = 'const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;if(e.main()!==42)throw Error("tag roundtrip failed");';
						if (!arrays)
							script += 'const count=e.__allocation_count||e["haxeon.memory.allocation_count"];const before=count();for(let i=0;i<1024;i++)if(e.main()!==42)throw Error("tag roundtrip changed");if(count()!==before)throw Error("tag or cached escape allocated");';
						var child = new sys.io.Process(command, target == HashLink ? [path] : ["-e", script, path]);
						var output = child.stdout.readAll().toString(),
							error = child.stderr.readAll().toString(),
							code = child.exitCode();
						child.close();
						if (code != (target == HashLink ? 42 : 0))
							throw '$target tag storage failed: $code $output $error';
					} catch (error:Dynamic) {
						if (sys.FileSystem.exists(path))
							sys.FileSystem.deleteFile(path);
						throw error;
					}
					sys.FileSystem.deleteFile(path);
					Sys.println('PASS: $target inline=$inlineEnabled variant=$variant nominal tags, scalar lanes and boxed roundtrip');
				}
	}
}
