package compiler.hl.persistence;

import compiler.hl.incremental.HlModuleAssembler;
import compiler.hl.incremental.HlModuleAssembler.HlAssemblerState;
import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;

/** Versioned physical backend baseline used to resume patch construction. */
class HlAssemblerStateCodec {
	public static function encode(assembler:HlModuleAssembler):Bytes {
		var state = assembler.exportState(), output = new BytesOutput();
		output.bigEndian = false;
		output.writeString("HAS");
		output.writeByte(1);
		output.writeByte(state.initialized ? 1 : 0);
		output.writeInt32(state.revision);
		output.writeInt32(state.publishedInts);
		output.writeInt32(state.publishedFloats);
		output.writeInt32(state.publishedStrings);
		output.writeInt32(state.publishedTypes);
		writeSection(output, state.symbols);
		writeSection(output, state.cache);
		return output.getBytes();
	}

	public static function decode(bytes:Bytes):HlModuleAssembler {
		var input = new BytesInput(bytes);
		input.bigEndian = false;
		try {
			if (input.readString(3) != "HAS")
				throw "Invalid HashLink assembler state";
			if (input.readByte() != 1)
				throw "Unsupported HashLink assembler state version";
			var initialized = input.readByte();
			if (initialized != 0 && initialized != 1)
				throw "Invalid HashLink assembler initialization state";
			var state:HlAssemblerState = {
				initialized: initialized == 1,
				revision: input.readInt32(),
				publishedInts: input.readInt32(),
				publishedFloats: input.readInt32(),
				publishedStrings: input.readInt32(),
				publishedTypes: input.readInt32(),
				symbols: readSection(input, bytes.length),
				cache: readSection(input, bytes.length)
			};
			if (input.position != bytes.length)
				throw "Trailing HashLink assembler state data";
			return HlModuleAssembler.fromState(state);
		} catch (error:haxe.io.Eof)
			throw "Truncated HashLink assembler state";
	}

	static function writeSection(output:BytesOutput, bytes:Bytes):Void {
		if (bytes.length > 0x10000000)
			throw "HashLink assembler section is too large";
		output.writeInt32(bytes.length);
		output.write(bytes);
	}

	static function readSection(input:BytesInput, total:Int):Bytes {
		var length = input.readInt32();
		if (length < 0 || length > 0x10000000 || length > total - input.position)
			throw "Invalid HashLink assembler section";
		return input.read(length);
	}
}
