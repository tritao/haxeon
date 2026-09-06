package compiler.hl.persistence;

import compiler.hl.incremental.HlFunctionCache;
import compiler.hl.incremental.HlFunctionCache.HlFunctionCacheState;
import compiler.ir.codec.IrTypeCodec;
import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;

/** Strict deterministic persistence for an {@link HlFunctionCache} baseline. */
class HlFunctionCacheStateCodec {
	static inline final MAX_ITEMS = 0x100000;

	public static function encode(state:HlFunctionCacheState):Bytes {
		var out = new BytesOutput();
		out.bigEndian = false;
		out.writeString("HFC");
		out.writeByte(1);
		out.writeInt32(state.nextStableId);
		writeCount(out, state.slots.length);
		for (name in state.slots)
			IrTypeCodec.writeString(out, name);
		writeCount(out, state.stableIds.length);
		for (entry in state.stableIds) {
			IrTypeCodec.writeString(out, entry.name);
			out.writeInt32(entry.id);
		}
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
			if (input.readString(3) != "HFC" || input.readByte() != 1)
				throw "Invalid function cache state";
			var next = input.readInt32(), slots = [
				for (_ in 0...readCount(input))
					IrTypeCodec.readString(input, bytes.length)
			], ids = [];
			for (_ in 0...readCount(input))
				ids.push({name: IrTypeCodec.readString(input, bytes.length), id: input.readInt32()});
			var signatures = [];
			for (_ in 0...readCount(input))
				signatures.push({
					name: IrTypeCodec.readString(input, bytes.length),
					signature: IrTypeCodec.readString(input, bytes.length)
				});
			var functions = [];
			for (_ in 0...readCount(input))
				functions.push({name: IrTypeCodec.readString(input, bytes.length), bytes: readBytes(input, bytes.length)});
			if (input.position != bytes.length)
				throw "Trailing function cache state data";
			return {
				slots: slots,
				stableIds: ids,
				signatures: signatures,
				functions: functions,
				nextStableId: next
			};
		} catch (error:haxe.io.Eof)
			throw "Truncated function cache state";
	}

	public static function restore(bytes:Bytes):HlFunctionCache
		return HlFunctionCache.fromState(decode(bytes));

	static function writeCount(out:BytesOutput, count:Int):Void {
		if (count < 0 || count > MAX_ITEMS)
			throw "Too many function cache entries";
		out.writeInt32(count);
	}

	static function readCount(input:BytesInput):Int {
		var count = input.readInt32();
		if (count < 0 || count > MAX_ITEMS)
			throw "Invalid function cache count";
		return count;
	}

	static function writeBytes(out:BytesOutput, bytes:Bytes):Void {
		if (bytes.length > 0x10000000)
			throw "Cached function is too large";
		out.writeInt32(bytes.length);
		out.write(bytes);
	}

	static function readBytes(input:BytesInput, total:Int):Bytes {
		var length = input.readInt32();
		if (length < 0 || length > 0x10000000 || length > total - input.position)
			throw "Invalid cached function length";
		return input.read(length);
	}
}
