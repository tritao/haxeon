package compiler.hl.patch;

import haxe.io.Bytes;
import haxe.io.BytesInput;

typedef HlPatchEnvelope = {
	final moduleId:Bytes;
	final baseRevision:Int;
	final revision:Int;
	final functionStableIds:Array<Int>;
	final relocationStableIds:Array<Int>;
}

/** Reads the HLP identity prefix before native patch publication. */
class HlPatchHeaderReader {
	public static function decode(bytes:Bytes):{moduleId:Bytes, baseRevision:Int, revision:Int} {
		if (bytes == null || bytes.length < 21)
			throw "Truncated HLP header";
		var input = new BytesInput(bytes);
		input.bigEndian = false;
		try {
			if (input.readString(3) != HlPatchFormat.MAGIC)
				throw "Invalid HLP magic";
			if (input.readByte() != HlPatchFormat.VERSION)
				throw "Unsupported HLP version";
			var moduleId = input.read(16),
				baseRevision = readUnsigned(input),
				revision = readUnsigned(input);
			if (revision <= baseRevision)
				throw "Invalid patch revision range";
			return {moduleId: moduleId, baseRevision: baseRevision, revision: revision};
		} catch (error:haxe.io.Eof) {
			throw "Truncated HLP header";
		}
	}

	/** Decode the header and validate the complete HLP section envelope. */
	public static function decodeComplete(bytes:Bytes):HlPatchEnvelope {
		return envelope(HlPatchReader.decode(bytes));
	}

	/** Project the canonical decoded patch into the identity policy view. */
	public static function envelope(patch:HlPatch):HlPatchEnvelope {
		if (patch == null)
			throw "Missing HLP patch model";
		var functionStableIds = [for (fn in patch.functions) fn.functionIndex],
			relocationStableIds:Array<Int> = [];
		for (fn in patch.functions)
			for (relocation in fn.relocations)
				relocationStableIds.push(relocation.stableId);
		return {
			moduleId: patch.moduleId,
			baseRevision: patch.baseRevision,
			revision: patch.revision,
			functionStableIds: functionStableIds,
			relocationStableIds: relocationStableIds
		};
	}

	static function readUnsigned(input:BytesInput):Int {
		var value = readIndex(input);
		if (value < 0)
			throw "Negative unsigned HLP index";
		return value;
	}

	static function readIndex(input:BytesInput):Int {
		var first = input.readByte();
		if ((first & 0x80) == 0)
			return first & 0x7F;
		if ((first & 0x40) == 0) {
			var value = input.readByte() | ((first & 31) << 8);
			return (first & 0x20) == 0 ? value : -value;
		}
		var value = ((first & 31) << 24) | (input.readByte() << 16) | (input.readByte() << 8) | input.readByte();
		return (first & 0x20) == 0 ? value : -value;
	}
}
