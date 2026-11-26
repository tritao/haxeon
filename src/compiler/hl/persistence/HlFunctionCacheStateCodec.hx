package compiler.hl.persistence;

import compiler.core.InternalError;
import compiler.hl.incremental.HlFunctionCache;
import compiler.hl.incremental.HlFunctionCache.HlFunctionCacheState;
import compiler.ir.codec.IrTypeCodec;
import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;

/** Strict deterministic persistence for an {@link HlFunctionCache} baseline. */
class HlFunctionCacheStateCodec {
	static inline final MAX_ITEMS = 0x100000;

	/** 2: the loader gives functions their stable ids, so the state keeps none. */
	static inline final VERSION = 2;

	public static function encode(state:HlFunctionCacheState):Bytes {
		var out = new BytesOutput();
		out.bigEndian = false;
		out.writeString("HFC");
		out.writeByte(VERSION);
		writeCount(out, state.slots.length);
		for (name in state.slots)
			IrTypeCodec.writeString(out, name);
		writeCount(out, state.signatures.length);
		for (entry in state.signatures) {
			IrTypeCodec.writeString(out, entry.name);
			IrTypeCodec.writeString(out, entry.signature);
		}
		writeCount(out, state.functions.length);
		for (entry in state.functions) {
			IrTypeCodec.writeString(out, entry.name);
			writeBytes(out, entry.bytes);
		}
		return out.getBytes();
	}

	public static function decode(bytes:Bytes):HlFunctionCacheState {
		var input = new BytesInput(bytes);
		input.bigEndian = false;
		try {
			if (input.readString(3) != "HFC" || input.readByte() != VERSION)
				throw new InternalError("Invalid function cache state");
			var slots = [
				for (_ in 0...readCount(input))
					IrTypeCodec.readString(input, bytes.length)
			];
			var signatures = [];
			for (_ in 0...readCount(input))
				signatures.push({
					name: IrTypeCodec.readString(input, bytes.length),
					signature: IrTypeCodec.readString(input, bytes.length)
				});
			var functions = [];
			for (_ in 0...readCount(input))
				functions.push({
					name: IrTypeCodec.readString(input, bytes.length),
					bytes: readBytes(input, bytes.length)
				});
			if (input.position != bytes.length)
				throw new InternalError("Trailing function cache state data");
			return {
				slots: slots,
				signatures: signatures,
				functions: functions
			};
		} catch (error:haxe.io.Eof)
			throw new InternalError("Truncated function cache state");
	}

	public static function restore(bytes:Bytes):HlFunctionCache
		return HlFunctionCache.fromState(decode(bytes));

	static function writeCount(out:BytesOutput, count:Int):Void {
		if (count < 0 || count > MAX_ITEMS)
			throw new InternalError("Too many function cache entries");
		out.writeInt32(count);
	}

	static function readCount(input:BytesInput):Int {
		var count = input.readInt32();
		if (count < 0 || count > MAX_ITEMS)
			throw new InternalError("Invalid function cache count");
		return count;
	}

	static function writeBytes(out:BytesOutput, bytes:Bytes):Void {
		if (bytes.length > 0x10000000)
			throw new InternalError("Cached function is too large");
		out.writeInt32(bytes.length);
		out.write(bytes);
	}

	static function readBytes(input:BytesInput, total:Int):Bytes {
		var length = input.readInt32();
		if (length < 0 || length > 0x10000000 || length > total - input.position)
			throw new InternalError("Invalid cached function length");
		return input.read(length);
	}
}
