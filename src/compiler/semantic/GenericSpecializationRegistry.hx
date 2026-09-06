package compiler.semantic;

import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;
import compiler.types.Type.CompilerType;
import compiler.semantic.SemanticSignature;

/** Structured identity and deterministic naming for generated generic ABI bodies. */
typedef GenericSpecialization = {
	final origin:String;
	final representations:Array<CompilerType>;
	final name:String;
	final isNew:Bool;
}

class GenericSpecializationRegistry {
	final names:Map<String, String> = [];

	public function new(?state:Bytes) {
		if (state != null)
			restore(state);
	}

	public function copy():GenericSpecializationRegistry {
		var result = new GenericSpecializationRegistry();
		for (key => name in names)
			result.names.set(key, name);
		return result;
	}

	public function exportState():Bytes {
		var keys = [for (key in names.keys()) key];
		keys.sort(Reflect.compare);
		var output = new BytesOutput();
		output.bigEndian = false;
		output.writeString("GSR");
		output.writeByte(1);
		output.writeInt32(keys.length);
		for (key in keys) {
			writeString(output, key);
			writeString(output, names.get(key));
		}
		return output.getBytes();
	}

	function restore(state:Bytes):Void {
		var input = new BytesInput(state);
		var restoredNames:Map<String, Bool> = [];
		input.bigEndian = false;
		try {
			if (input.readString(3) != "GSR" || input.readByte() != 1)
				throw "Invalid generic specialization state";
			var count = input.readInt32();
			if (count < 0 || count > 0x100000)
				throw "Invalid generic specialization count";
			for (_ in 0...count) {
				var key = readString(input), name = readString(input);
				if (names.exists(key))
					throw "Duplicate generic specialization";
				if (restoredNames.exists(name))
					throw "Generic specialization name collision";
				names.set(key, name);
				restoredNames.set(name, true);
			}
			if (input.position != state.length)
				throw "Trailing generic specialization state";
		} catch (error:haxe.io.Eof) {
			throw "Truncated generic specialization state";
		}
	}

	static function writeString(output:BytesOutput, value:String):Void {
		var bytes = Bytes.ofString(value);
		output.writeInt32(bytes.length);
		output.write(bytes);
	}

	static function readString(input:BytesInput):String {
		var length = input.readInt32();
		if (length < 0 || length > 0x100000)
			throw "Invalid generic specialization string";
		return input.readString(length);
	}

	public function request(origin:String, representations:Array<CompilerType>, ?policies:Array<String>):GenericSpecialization {
		var signature = [for (type in representations) SemanticSignature.type(type)].join(","),
			policy = policies == null ? "legacy" : policies.join(","),
			key = origin + "[" + policy + "]<" + signature + ">";
		if (names.exists(key))
			return {
				origin: origin,
				representations: representations.copy(),
				name: names.get(key),
				isNew: false
			};
		var name = '$' + 'generic:$key';
		names.set(key, name);
		return {
			origin: origin,
			representations: representations.copy(),
			name: name,
			isNew: true
		};
	}
}
