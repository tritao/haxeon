package compiler.backend.wasm;

import compiler.abi.PatchPlanner;
import compiler.abi.PatchPlanner.PatchDecision;
import compiler.abi.RuntimeAbi;
import compiler.ir.IrFunction;
import compiler.ir.Ir.IrProgram;
import compiler.ir.codec.IrTypeCodec;
import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;

typedef WasmFunctionIdentity = {
	final name:String;
	final stableId:Int;
	final signature:String;
}

typedef WasmPatchArtifact = {
	final bytes:Bytes;
	final manifest:Bytes;
	final decision:PatchDecision;
	final changed:Array<String>;
}

typedef WasmTableIdentity = {
	final name:String;
	final slot:Int;
	final stableId:Int;
}

/** Stable semantic manifest used to validate replacement Wasm table entries. */
class WasmPatch {
	public static inline final VERSION:Int = 1;

	public static function identities(program:IrProgram):Array<WasmFunctionIdentity> {
		var result:Array<WasmFunctionIdentity> = [];
		for (fn in program.functions)
			result.push({name: fn.name, stableId: stableId(fn.name), signature: signature(fn)});
		result.sort(function(left, right) return Reflect.compare(left.name, right.name));
		return result;
	}

	public static function manifest(program:IrProgram, ?changed:Array<String>):Bytes {
		var selected:Map<String, Bool> = null;
		if (changed != null) {
			selected = [];
			for (name in changed)
				selected.set(name, true);
		}
		var all = identities(program), output = new BytesOutput();
		output.bigEndian = false;
		output.writeString("HWP");
		output.writeByte(VERSION);
		var entries = selected == null ? all : [for (entry in all) if (selected.exists(entry.name)) entry];
		output.writeInt32(entries.length);
		for (entry in entries) {
			IrTypeCodec.writeString(output, entry.name);
			output.writeInt32(entry.stableId);
			IrTypeCodec.writeString(output, entry.signature);
		}
		return output.getBytes();
	}

	/** Maps the stable function names used by host-side table publication to slots. */
	public static function tableManifest(slots:Map<String, Int>):Bytes {
		var names = [for (name in slots.keys()) name];
		names.sort(Reflect.compare);
		var output = new BytesOutput();
		output.bigEndian = false;
		output.writeString("HWT");
		output.writeByte(VERSION);
		output.writeInt32(names.length);
		for (name in names) {
			IrTypeCodec.writeString(output, name);
			output.writeInt32(stableId(name));
			output.writeInt32(slots.get(name));
		}
		return output.getBytes();
	}

	public static function readManifest(bytes:Bytes):Array<WasmFunctionIdentity> {
		var input = new BytesInput(bytes);
		input.bigEndian = false;
		if (input.readString(3) != "HWP" || input.readByte() != VERSION)
			throw "Invalid Wasm patch manifest";
		var result:Array<WasmFunctionIdentity> = [];
		for (_ in 0...readCount(input, bytes.length)) {
			var name = IrTypeCodec.readString(input, bytes.length),
				id = input.readInt32(),
				signature = IrTypeCodec.readString(input, bytes.length);
			if (id != stableId(name))
				throw 'Invalid stable ID for Wasm patch function "$name"';
			result.push({name: name, stableId: id, signature: signature});
		}
		if (input.position != bytes.length)
			throw "Trailing Wasm patch manifest data";
		return result;
	}

	public static function readTableManifest(bytes:Bytes):Array<WasmTableIdentity> {
		var input = new BytesInput(bytes);
		input.bigEndian = false;
		if (input.readString(3) != "HWT" || input.readByte() != VERSION)
			throw "Invalid Wasm table manifest";
		var result:Array<WasmTableIdentity> = [];
		for (_ in 0...readCount(input, bytes.length)) {
			var name = IrTypeCodec.readString(input, bytes.length),
				id = input.readInt32(),
				slot = input.readInt32();
			if (id != stableId(name) || slot < 0)
				throw 'Invalid Wasm table identity for "$name"';
			result.push({name: name, stableId: id, slot: slot});
		}
		if (input.position != bytes.length)
			throw "Trailing Wasm table manifest data";
		return result;
	}

	public static function plan(previous:Null<IrProgram>, next:IrProgram):PatchDecision
		return PatchPlanner.plan(previous == null ? null : RuntimeAbi.describe(previous), RuntimeAbi.describe(next));

	static function signature(fn:IrFunction):String
		return "(" + [for (argument in fn.arguments) Std.string(argument.type)].join(",") + ")->" + Std.string(fn.result);

	static function stableId(name:String):Int {
		var hash:Int = -2128831035;
		for (index in 0...name.length) {
			hash = Std.int(hash ^ name.charCodeAt(index));
			hash = Std.int(hash * 16777619);
		}
		return hash;
	}

	static function readCount(input:BytesInput, limit:Int):Int {
		var count = input.readInt32();
		if (count < 0 || count > 0x100000 || input.position > limit)
			throw "Invalid Wasm patch manifest count";
		return count;
	}
}
