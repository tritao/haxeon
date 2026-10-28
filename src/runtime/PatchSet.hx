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
		var length:Int = bytes.length;
		// Magic "HLP", version, 16-byte module ID.
		if (length < 20 || bytes.get(0) != "H".code || bytes.get(1) != "L".code || bytes.get(2) != "P".code)
			return true;
		var cursor:Array<Int> = [20];
		readIndex(cursor); // base revision
		readIndex(cursor); // revision
		var sections:Int = readIndex(cursor);
		for (_ in 0...sections) {
			if (cursor[0] < 0 || cursor[0] >= length)
				return true;
			var tag:Int = bytes.get(cursor[0]);
			cursor[0]++;
			var size:Int = readIndex(cursor);
			if (tag == GUARDS)
				return true;
			if (size < 0)
				return true;
			cursor[0] += size;
		}
		return cursor[0] < 0 || cursor[0] > length;
	}

	static inline final GUARDS:Int = 9;

	/** HLP's variable-length index (`HlPatchReader.readIndex`), read at `cursor[0]`, which it advances; -1 past the end. */
	function readIndex(cursor:Array<Int>):Int {
		var at:Int = cursor[0];
		if (at < 0 || at >= bytes.length) {
			cursor[0] = -1;
			return -1;
		}
		var first:Int = bytes.get(at);
		if ((first & 0x80) == 0) {
			cursor[0] = at + 1;
			return first & 0x7F;
		}
		if ((first & 0x40) == 0) {
			if (at + 1 >= bytes.length) {
				cursor[0] = -1;
				return -1;
			}
			cursor[0] = at + 2;
			var v:Int = bytes.get(at + 1) | ((first & 31) << 8);
			return (first & 0x20) == 0 ? v : -v;
		}
		if (at + 3 >= bytes.length) {
			cursor[0] = -1;
			return -1;
		}
		cursor[0] = at + 4;
		var v:Int = ((first & 31) << 24) | (bytes.get(at + 1) << 16) | (bytes.get(at + 2) << 8) | bytes.get(at + 3);
		return (first & 0x20) == 0 ? v : -v;
	}
}
