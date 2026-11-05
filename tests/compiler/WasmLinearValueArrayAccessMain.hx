import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrType;
import compiler.ir.IrValueLaneReference;
import compiler.ir.Ir.IrProgram;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.backend.wasm.WasmLayout;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmEncoder;
import compiler.backend.wasm.WasmTarget;
import compiler.backend.wasm.linear.WasmLinearValueArrays;

/** Run the Wasm32 lane primitives on packed storage, including validity and adjacent fields. */
class WasmLinearValueArrayAccessMain {
	static function main():Void {
		var array:IrType = Array(Dyn), carrier = IrValueLaneReference.type();
		var natives:Array<IrNative> = [
			{name:"read32", library:"haxeon_runtime", symbol:"__value_array_read_i32", arguments:[array,I32,I32,I32,Bool], result:I32},
			{name:"write32", library:"haxeon_runtime", symbol:"__value_array_write_i32", arguments:[array,I32,I32,I32,I32], result:Void},
			{name:"read64", library:"haxeon_runtime", symbol:"__value_array_read_i64", arguments:[array,I32,I32,I32,Bool], result:I64},
			{name:"write64", library:"haxeon_runtime", symbol:"__value_array_write_i64", arguments:[array,I32,I32,I32,I64], result:Void},
			{name:"readBool", library:"haxeon_runtime", symbol:"__value_array_read_bool", arguments:[array,I32,I32], result:Bool},
			{name:"writeBool", library:"haxeon_runtime", symbol:"__value_array_write_bool", arguments:[array,I32,I32,Bool], result:Void},
			{name:"readF32", library:"haxeon_runtime", symbol:"__value_array_read_f32", arguments:[array,I32,I32], result:F32},
			{name:"writeF32", library:"haxeon_runtime", symbol:"__value_array_write_f32", arguments:[array,I32,I32,F32], result:Void},
			{name:"readF64", library:"haxeon_runtime", symbol:"__value_array_read_f64", arguments:[array,I32,I32], result:F64},
			{name:"writeF64", library:"haxeon_runtime", symbol:"__value_array_write_f64", arguments:[array,I32,I32,F64], result:Void},
			{name:"readPtr", library:"haxeon_runtime", symbol:"__value_array_read_ptr", arguments:[array,I32,I32,I32], result:RawPtr},
			{name:"writePtr", library:"haxeon_runtime", symbol:"__value_array_write_ptr", arguments:[array,I32,I32,I32,RawPtr], result:Void},
			{name:"readType", library:"haxeon_runtime", symbol:"__value_array_read_type", arguments:[array,I32,I32,I32], result:TypeRef},
			{name:"writeType", library:"haxeon_runtime", symbol:"__value_array_write_type", arguments:[array,I32,I32,I32,TypeRef], result:Void},
			{name:"readCallback", library:"haxeon_runtime", symbol:"__value_array_read_callback", arguments:[array,I32,I32], result:Abstract("native_callback")},
			{name:"writeCallback", library:"haxeon_runtime", symbol:"__value_array_write_callback", arguments:[array,I32,I32,Abstract("native_callback")], result:Void},
			{name:"readRef", library:"haxeon_runtime", symbol:"__value_array_read_ref", arguments:[array,I32,I32], result:carrier},
			{name:"writeRef", library:"haxeon_runtime", symbol:"__value_array_write_ref", arguments:[array,I32,I32,carrier], result:Void},
			{name:"clearRef", library:"haxeon_runtime", symbol:"__value_array_clear_ref", arguments:[array,I32,I32], result:Void},
			{name:"clearScalar", library:"haxeon_runtime", symbol:"__value_array_clear_scalar", arguments:[array,I32,I32,I32], result:Void},
			{name:"initialized", library:"haxeon_runtime", symbol:"__value_array_is_initialized", arguments:[array,I32], result:Bool},
			{name:"validate", library:"haxeon_runtime", symbol:"__value_array_validate", arguments:[array,I32], result:Void},
			{name:"mark", library:"haxeon_runtime", symbol:"__value_array_mark", arguments:[array,I32], result:Void}
		];
		var module = new WasmModule("linear-value-array-access"); module.memoryMin = 1; module.exportMemory = true;
		for (native in natives) module.exports.push({name:native.name, functionIndex:module.addFunction(WasmLinearValueArrays.build(module, native))});
		var bytes = WasmEncoder.encode(module), directory = Sys.getEnv("TMPDIR");
		if (directory == null || directory.length == 0) directory = ".";
		var path = directory + "/haxeon-linear-lanes-" + Std.random(0x7fffffff) + ".wasm";
		try {
			sys.io.File.saveBytes(path, bytes);
			var js = 'const fs=require("fs"), i=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))), e=i.exports; '
				+ 'const d=new DataView(e.memory.buffer), a=128; '
				+ 'd.setInt32(a+4,${WasmLayout.VALUE_ARRAY_MARKER},true); d.setInt32(a+8,2,true); d.setInt32(a+12,4,true); '
				+ 'd.setInt32(a+16,512,true); d.setInt32(a+24,96,true); d.setInt32(a+28,2,true); d.setInt32(a+32,1024,true); '
				+ 'd.setInt32(a+36,1,true); d.setUint8(560,3); '
				+ 'e.write32(a,0,0,8,-5); e.write32(a,0,16,8,93); e.write32(a,0,24,32,0x12345678); '
				+ 'e.write64(a,1,24,64,-1234567n); '
				+ 'if(e.read32(a,0,0,8,1)!==-5 || e.read32(a,0,16,8,0)!==93 || e.read32(a,0,24,32,0)!==0x12345678 || e.read64(a,1,24,64,1)!==-1234567n) throw Error("integers"); '
				+ 'e.clearScalar(a,0,16,8); if(e.read32(a,0,16,8,0)!==0 || e.read32(a,0,24,32,0)!==0x12345678) throw Error("clear"); '
				+ 'e.writeBool(a,0,8,1); e.writeF32(a,0,56,1.5); e.writeF64(a,1,24,-2.25); '
				+ 'if(e.readBool(a,0,8)!==1 || e.readF32(a,0,56)!==1.5 || e.readF64(a,1,24)!==-2.25) throw Error("float/bool"); '
				+ 'e.writePtr(a,0,24,32,111); e.writeType(a,0,56,32,222); e.writeCallback(a,1,24,333); '
				+ 'if(e.readPtr(a,0,24,32)!==111 || e.readType(a,0,56,32)!==222 || e.readCallback(a,1,24)!==333) throw Error("handles"); '
				+ 'e.writeRef(a,1,1,1234); if(e.readRef(a,1,1)!==1234) throw Error("reference"); e.clearRef(a,1,1); if(e.readRef(a,1,1)!==0) throw Error("clear ref"); '
				+ 'for(const test of [()=>e.read32(a,-1,0,8,0),()=>e.read32(a,0,88,16,0),()=>e.readRef(a,0,2)]) { let trapped=false; try{test()}catch(x){trapped=x instanceof WebAssembly.RuntimeError} if(!trapped) throw Error("bounds"); } '
				+ 'd.setUint8(560,1); if(e.initialized(a,0)!==1 || e.initialized(a,1)!==0) throw Error("validity state"); '
				+ 'let trapped=false; try{e.validate(a,1)}catch(x){trapped=x instanceof WebAssembly.RuntimeError} if(!trapped) throw Error("validity"); '
				+ 'e.mark(a,1); e.validate(a,1); if(e.initialized(a,1)!==1 || d.getUint8(560)!==3) throw Error("mark"); '
				+ 'd.setInt32(a+36,0,true); if(e.initialized(a,1)!==1) throw Error("implicit validity");';
			var process = new sys.io.Process("node", ["-e", js, path]), error = process.stderr.readAll().toString(), status = process.exitCode();
			process.close();
			if (status != 0) throw 'Wasm32 value-array access failed ($status): $error';
		} catch (error:Dynamic) { if (sys.FileSystem.exists(path)) sys.FileSystem.deleteFile(path); throw error; }
		if (sys.FileSystem.exists(path)) sys.FileSystem.deleteFile(path);
		// Exercise the production allocator and collector with a reference reachable only through the new lane.
		var ownerType:IrType = Obj("LinearValueArrayOwner"), init = new IrBuilder(), initArray = init.argument("array", array),
			owner = init.newObject("LinearValueArrayOwner");
		init.fieldSet(owner, "value", init.constInt(42));
		var ownerCarrier = init.call(IrValueLaneReference.PACK, [owner], carrier);
		init.call("__value_array_write_ref", [initArray, init.constInt(0), init.constInt(0), ownerCarrier], Void);
		init.call("__value_array_write_ref", [initArray, init.constInt(0), init.constInt(1), ownerCarrier], Void);
		init.call("__value_array_mark", [initArray, init.constInt(0)], Void);
		init.returnValue(init.constVoid());
		var main = new IrBuilder(), lane = main.call("$test:linear-allocate", [main.constInt(1), main.typeValue(ownerType),
			main.constInt(32), main.constInt(2), main.constInt(32), main.constBool(true)], array);
		main.call("init", [lane], Void);
		main.call("__value_array_write_i32", [lane, main.constInt(0), main.constInt(0), main.constInt(32), main.constInt(73)], Void);
		main.call("__value_array_ensure", [lane, main.constInt(9)], Void);
		main.call("__value_array_insert_empty", [lane, main.constInt(0)], I32);
		main.call("__value_array_resize", [lane, main.constInt(2)], Void);
		var snapshot = main.call("__value_array_copy", [lane], array), slice = main.call("__value_array_slice", [lane, main.constInt(-1), main.constInt(2)], array);
		main.call("__value_array_reverse", [snapshot], Void);
		var joined = main.call("__value_array_concat", [snapshot, slice], array), removed = main.call("__value_array_splice", [joined, main.constInt(1), main.constInt(1)], array);
		main.call("__value_array_clear", [lane, main.constInt(1)], Void);
		var clearInitialized = main.call("__value_array_is_initialized", [lane, main.constInt(1)], Bool);
		main.call("__value_array_mark", [lane, main.constInt(1)], Void);
		var clearScalar = main.call("__value_array_read_i32", [lane, main.constInt(1), main.constInt(0), main.constInt(32), main.constBool(true)], I32),
			clearCarrier = main.call("__value_array_read_ref", [lane, main.constInt(1), main.constInt(0)], carrier),
			clearOwner = main.call(IrValueLaneReference.UNPACK, [clearCarrier], ownerType),
			clearSecondCarrier = main.call("__value_array_read_ref", [lane, main.constInt(1), main.constInt(1)], carrier),
			clearSecondOwner = main.call(IrValueLaneReference.UNPACK, [clearSecondCarrier], ownerType);

		for (_ in 0...12) main.call("__array_alloc_ref", [main.constInt(8)], array);
		var loadedCarrier = main.call("__value_array_read_ref", [joined, main.constInt(1), main.constInt(0)], carrier),
			loaded = main.call(IrValueLaneReference.UNPACK, [loadedCarrier], ownerType),
			scalar = main.call("__value_array_read_i32", [slice, main.constInt(0), main.constInt(0), main.constInt(32), main.constBool(true)], I32),
			newInitialized = main.call("__value_array_is_initialized", [removed, main.constInt(0)], Bool), checkScalar = main.createBlock(),
			checkNew = main.createBlock(), checkClear = main.createBlock(), checkZero = main.createBlock(), checkNull = main.createBlock(), checkSecondNull = main.createBlock(),
			success = main.createBlock(), failure = main.createBlock();
		main.branch(main.equal(main.fieldGet(loaded, "value", I32), main.constInt(42)), checkScalar, failure);
		main.select(checkScalar); main.branch(main.equal(scalar, main.constInt(73)), checkNew, failure);
		main.select(checkNew); main.branch(newInitialized, failure, checkClear);
		main.select(checkClear); main.branch(clearInitialized, failure, checkZero);
		main.select(checkZero); main.branch(main.equal(clearScalar, main.constInt(0)), checkNull, failure);
		main.select(checkNull); main.branch(main.equal(clearOwner, main.constNull(ownerType)), checkSecondNull, failure);
		main.select(checkSecondNull); main.branch(main.equal(clearSecondOwner, main.constNull(ownerType)), success, failure);
		main.select(success); main.returnValue(main.constInt(42));
		main.select(failure); main.returnValue(main.constInt(0));
		var program = new IrProgram("main");
		program.objects = [{name:"LinearValueArrayOwner", isValue:false, base:null, interfaces:[], methods:[], fields:[{name:"value", type:I32}]}];
		program.functions = [new IrFunction("main", [], I32, main.blocks), new IrFunction("init", init.arguments, Void, init.blocks)];
		program.natives = [
			{name:"$test:linear-allocate", library:"haxeon_runtime", symbol:"__value_array_alloc", arguments:[I32,TypeRef,I32,I32,I32,Bool], result:array},
			{name:"__array_alloc_ref", library:"haxeon_runtime", symbol:"__array_alloc_ref", arguments:[I32], result:array},
			{name:"__value_array_write_ref", library:"haxeon_runtime", symbol:"__value_array_write_ref", arguments:[array,I32,I32,carrier], result:Void},
			{name:"__value_array_read_ref", library:"haxeon_runtime", symbol:"__value_array_read_ref", arguments:[array,I32,I32], result:carrier},
			{name:"__value_array_mark", library:"haxeon_runtime", symbol:"__value_array_mark", arguments:[array,I32], result:Void},
			{name:"__value_array_ensure", library:"haxeon_runtime", symbol:"__value_array_ensure", arguments:[array,I32], result:Void},
			{name:"__value_array_insert_empty", library:"haxeon_runtime", symbol:"__value_array_insert_empty", arguments:[array,I32], result:I32},
			{name:"__value_array_resize", library:"haxeon_runtime", symbol:"__value_array_resize", arguments:[array,I32], result:Void},
			{name:"__value_array_clear", library:"haxeon_runtime", symbol:"__value_array_clear", arguments:[array,I32], result:Void},
			{name:"__value_array_copy", library:"haxeon_runtime", symbol:"__value_array_copy", arguments:[array], result:array},
			{name:"__value_array_slice", library:"haxeon_runtime", symbol:"__value_array_slice", arguments:[array,I32,I32], result:array},
			{name:"__value_array_reverse", library:"haxeon_runtime", symbol:"__value_array_reverse", arguments:[array], result:Void},
			{name:"__value_array_concat", library:"haxeon_runtime", symbol:"__value_array_concat", arguments:[array,array], result:array},
			{name:"__value_array_splice", library:"haxeon_runtime", symbol:"__value_array_splice", arguments:[array,I32,I32], result:array},
			{name:"__value_array_is_initialized", library:"haxeon_runtime", symbol:"__value_array_is_initialized", arguments:[array,I32], result:Bool},
			{name:"__value_array_write_i32", library:"haxeon_runtime", symbol:"__value_array_write_i32", arguments:[array,I32,I32,I32,I32], result:Void},
			{name:"__value_array_read_i32", library:"haxeon_runtime", symbol:"__value_array_read_i32", arguments:[array,I32,I32,I32,Bool], result:I32}
		];
		var realBytes = new compiler.backend.wasm.WasmBackend().compile(program, {target:Wasm32, wasmGcStress:true, debugNames:true}).bytes;
		try {
			sys.io.File.saveBytes(path, realBytes);
			var js = 'const fs=require("fs"), i=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))); '
				+ 'if(i.exports.main()!==42) throw Error("reference lane did not survive GC");';
			var process = new sys.io.Process("node", ["-e", js, path]), error = process.stderr.readAll().toString(), status = process.exitCode();
			process.close();
			if (status != 0) throw 'Wasm32 value-array GC stress failed ($status): $error';
		} catch (error:Dynamic) { if (sys.FileSystem.exists(path)) sys.FileSystem.deleteFile(path); throw error; }
		if (sys.FileSystem.exists(path)) sys.FileSystem.deleteFile(path);
		Sys.println("PASS: Wasm32 value-array lane access");
	}
}
