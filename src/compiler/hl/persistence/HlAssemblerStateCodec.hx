package compiler.hl.persistence;

import compiler.core.InternalError;
import compiler.hl.incremental.HlModuleAssembler;
import compiler.hl.incremental.HlModuleAssembler.HlAssemblerState;
import compiler.ir.model.Ir.IrNative;
import compiler.ir.codec.IrTypeCodec;
import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;

/** Versioned physical backend baseline used to resume patch construction. */
class HlAssemblerStateCodec {
	/** 6: the digests of the module's sections, which a live patch compares the next build's with. */
	static inline final VERSION = 6;

	public static function encode(assembler:HlModuleAssembler):Bytes {
		var state = assembler.exportState(), output = new BytesOutput();
		output.bigEndian = false;
		output.writeString("HAS");
		output.writeByte(VERSION);
		output.writeByte(state.initialized ? 1 : 0);
		output.writeInt32(state.revision);
		output.writeInt32(state.publishedInts);
		output.writeInt32(state.publishedFloats);
		output.writeInt32(state.publishedStrings);
		output.writeInt32(state.publishedTypes);
		output.writeInt32(state.publishedGlobals == null ? 0 : state.publishedGlobals);
		writeSection(output, state.symbols);
		writeSection(output, state.cache);
		writeNatives(output, state.runtimeNatives);
		var dispatch = state.dispatchNatives;
		output.writeByte(dispatch == null ? 0 : 1);
		if (dispatch != null) {
			output.writeInt32(dispatch.length);
			for (name in dispatch)
				IrTypeCodec.writeString(output, name);
		}
		var retired = state.retiredFields == null ? [] : state.retiredFields;
		output.writeInt32(retired.length);
		for (name in retired)
			IrTypeCodec.writeString(output, name);
		output.writeInt32(state.sections.length);
		for (section in state.sections) {
			IrTypeCodec.writeString(output, section.path);
			IrTypeCodec.writeString(output, section.digest);
		}
		return output.getBytes();
	}

	public static function decode(bytes:Bytes):HlModuleAssembler {
		var input = new BytesInput(bytes);
		input.bigEndian = false;
		try {
			if (input.readString(3) != "HAS")
				throw new InternalError("Invalid HashLink assembler state");
			var version = input.readByte();
			if (version != VERSION)
				throw new InternalError("Unsupported HashLink assembler state version");
			var initialized = input.readByte();
			if (initialized != 0 && initialized != 1)
				throw new InternalError("Invalid HashLink assembler initialization state");
			var state:HlAssemblerState = {
				initialized: initialized == 1,
				revision: input.readInt32(),
				publishedInts: input.readInt32(),
				publishedFloats: input.readInt32(),
				publishedStrings: input.readInt32(),
				publishedTypes: input.readInt32(),
				publishedGlobals: input.readInt32(),
				symbols: readSection(input, bytes.length),
				cache: readSection(input, bytes.length),
				runtimeNatives: readNatives(input, bytes.length),
				dispatchNatives: readDispatchNatives(input, bytes.length),
				retiredFields: [for (_ in 0...readCount(input)) IrTypeCodec.readString(input, bytes.length)],
				sections: [for (_ in 0...readCount(input)) {
					path: IrTypeCodec.readString(input, bytes.length),
					digest: IrTypeCodec.readString(input, bytes.length)
				}]
			};
			if (input.position != bytes.length)
				throw new InternalError("Trailing HashLink assembler state data");
			return HlModuleAssembler.fromState(state);
		} catch (error:haxe.io.Eof)
			throw new InternalError("Truncated HashLink assembler state");
	}

	static function writeNatives(out:BytesOutput, natives:Array<IrNative>):Void {
		out.writeInt32(natives.length);
		for (native in natives) {
			IrTypeCodec.writeString(out, native.name);
			IrTypeCodec.writeString(out, native.library);
			IrTypeCodec.writeString(out, native.symbol);
			out.writeInt32(native.arguments.length);
			for (type in native.arguments)
				IrTypeCodec.writeType(out, type, 0);
			IrTypeCodec.writeType(out, native.result, 0);
			var dependencies = native.generatedFunctionDependencies;
			out.writeInt32(dependencies == null ? 0 : dependencies.length);
			if (dependencies != null)
				for (name in dependencies)
					IrTypeCodec.writeString(out, name);
		}
	}

	static function readDispatchNatives(input:BytesInput, limit:Int):Null<Array<String>> {
		var present = input.readByte();
		if (present == 0)
			return null;
		if (present != 1)
			throw new InternalError("Invalid dispatch native presence");
		return [for (_ in 0...readCount(input)) IrTypeCodec.readString(input, limit)];
	}

	static function readCount(input:BytesInput):Int {
		var count = input.readInt32();
		if (count < 0 || count > 0x100000)
			throw new InternalError("Invalid native import count");
		return count;
	}

	static function readNatives(input:BytesInput, limit:Int):Array<IrNative> {
		var result:Array<IrNative> = [], names:Map<String, Bool> = [];
		for (_ in 0...readCount(input)) {
			var name = IrTypeCodec.readString(input, limit),
				library = IrTypeCodec.readString(input, limit),
				symbol = IrTypeCodec.readString(input, limit),
				arguments = [for (_ in 0...readCount(input)) IrTypeCodec.readType(input, limit, 0)],
				returnType = IrTypeCodec.readType(input, limit, 0),
				dependencies = [for (_ in 0...readCount(input)) IrTypeCodec.readString(input, limit)];
			if (names.exists(name))
				throw new InternalError("Duplicate native import in assembler state");
			names.set(name, true);
			result.push({
				name: name,
				library: library,
				symbol: symbol,
				arguments: arguments,
				result: returnType,
				generatedFunctionDependencies: dependencies.length == 0 ? null : dependencies
			});
		}
		return result;
	}

	static function writeSection(output:BytesOutput, bytes:Bytes):Void {
		if (bytes.length > 0x10000000)
			throw new InternalError("HashLink assembler section is too large");
		output.writeInt32(bytes.length);
		output.write(bytes);
	}

	static function readSection(input:BytesInput, total:Int):Bytes {
		var length = input.readInt32();
		if (length < 0 || length > 0x10000000 || length > total - input.position)
			throw new InternalError("Invalid HashLink assembler section");
		return input.read(length);
	}
}
