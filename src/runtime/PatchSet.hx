package runtime;

import haxe.io.Bytes;

/** Validated patch artifact and the stable function IDs it is expected to replace. */
class PatchSet {
	public final baseRevision:Int;
	public final revision:Int;
	public final bytes:Bytes;
	public final changedFunctions:Array<Int>;

	public function new(baseRevision:Int, revision:Int, bytes:Bytes, changedFunctions:Array<Int>) {
		if (baseRevision < 0 || revision <= baseRevision)
			throw new RuntimeError(RuntimeStatus.BadArgument, "Patch revisions must advance from a non-negative base");
		if (bytes == null || bytes.length == 0 || changedFunctions == null || changedFunctions.length == 0)
			throw new RuntimeError(RuntimeStatus.BadArgument, "Patch artifact and changed functions are required");
		this.baseRevision = baseRevision;
		this.revision = revision;
		this.bytes = bytes;
		this.changedFunctions = changedFunctions.copy();
	}

	/**
	 * Whether the patch carries guards: functions it drops that stored closures may still reach (HLP section 9, written by
	 * `HlPatchWriter`). Only such a patch needs the app to let go of its UI first (`Runtime.patchSetRebuilding`). Reads the
	 * section headers alone; an artifact it cannot read counts as guarded, the safe answer.
	 */
	public function hasGuards():Bool {
		var input = new haxe.io.BytesInput(bytes);
		input.bigEndian = false;
		try {
			if (input.readString(3) != "HLP")
				return true;
			input.position += 1 + 16; // version, module ID
			readIndex(input); // base revision
			readIndex(input); // revision
			for (_ in 0...readIndex(input)) {
				var tag = input.readByte(), length = readIndex(input);
				if (tag == GUARDS)
					return true;
				input.position += length;
			}
			return false;
		} catch (_:Dynamic) {
			return true;
		}
	}

	static inline final GUARDS:Int = 9;

	/** HLP's variable-length index (`HlPatchReader.readIndex`). */
	static function readIndex(input:haxe.io.BytesInput):Int {
		var first = input.readByte();
		if ((first & 0x80) == 0)
			return first & 0x7F;
		if ((first & 0x40) == 0) {
			var v = input.readByte() | ((first & 31) << 8);
			return (first & 0x20) == 0 ? v : -v;
		}
		var v = ((first & 31) << 24) | (input.readByte() << 16) | (input.readByte() << 8) | input.readByte();
		return (first & 0x20) == 0 ? v : -v;
	}
}
