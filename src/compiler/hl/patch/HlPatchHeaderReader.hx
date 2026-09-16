package compiler.hl.patch;

import haxe.io.Bytes;
import haxe.io.BytesInput;

typedef HlPatchEnvelope = {
	final moduleId:Bytes;
	final baseRevision:Int;
	final revision:Int;
	final functionStableIds:Array<Int>;
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
			var sectionCount = readUnsigned(input),
				functionStableIds:Array<Int> = [];
			if (sectionCount < 2 || sectionCount > bytes.length)
				throw "Invalid HLP section count";
			var symbols = false, functions = false;
			for (_ in 0...sectionCount) {
				var tag = input.readByte(),
					length = readUnsigned(input),
					end = input.position + length;
				if (end < input.position || end > bytes.length)
					throw "Truncated HLP section";
				if (tag == 1) {
					if (symbols)
						throw "Duplicate HLP symbols section";
					symbols = true;
				} else if (tag == 2) {
					if (functions)
						throw "Duplicate HLP functions section";
					functions = true;
					var functionCount = readUnsigned(input);
					for (_ in 0...functionCount) {
						var functionLength = readUnsigned(input),
							functionEnd = input.position + functionLength;
						if (functionEnd < input.position || functionEnd > end)
							throw "Truncated HLP function";
						var stableId = readUnsigned(input);
						for (existing in functionStableIds)
							if (existing == stableId)
								throw "Duplicate HLP function identity";
						functionStableIds.push(stableId);
						input.read(functionEnd - input.position);
					}
				}
				input.read(end - input.position);
			}
			if (!symbols || !functions || functionStableIds.length == 0)
				throw "Missing required HLP section";
			if (input.position != bytes.length)
				throw "Trailing HLP data";
			return {
				moduleId: moduleId,
				baseRevision: baseRevision,
				revision: revision,
				functionStableIds: functionStableIds
			};
		} catch (error:haxe.io.Eof) {
			throw "Truncated HLP section envelope";
		}
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
