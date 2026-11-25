package compiler.core;

import compiler.core.Source.SourceFile;
import sys.thread.Mutex;

/**
 * A place source positions are counted from: a member declaration of a file (a method, a field, an enum constructor), named by
 * its path and its name in the file, or the whole file. The IR keeps a position as its anchor and the distance from it
 * (`SourceLocation`), so text moved above a declaration leaves the code of everything in it as it was; what a build writes out
 * finds the anchor's place in that build's text (`SourceAnchors`). See docs/design/WARM_REBUILD_REUSE.md.
 *
 * Interned: one anchor per path and name, numbered in the order the process first sees them. A number may index tables but must
 * never reach what a compile writes or decide its order: a build names an anchor by its `path` and `key`.
 */
@:nullSafety(Strict)
class SourceAnchor {
	/** By path, then by name in the file: a map per file, so the path is not spelled again in every declaration's key. */
	@:processWide("interned anchors: a path and name always denote the same anchor, and the table only grows")
	static final byPath:Map<String, Map<String, SourceAnchor>> = [];

	@:processWide("guards interning, which the parse threads and the compile thread may both do")
	static final lock = new Mutex();

	static inline final CHUNK_BITS = 12;
	static inline final CHUNK_SIZE = 1 << CHUNK_BITS;

	/** The anchors by id, in chunks that never move once made, so `at` needs no lock (as `IrSymbol` keeps its symbols). */
	@:processWide("interned anchors, by id: the chunks only fill")
	static final chunks:Array<Null<Array<SourceAnchor>>> = [for (_ in 0...1 << 14) null];

	@:processWide("how many anchors are interned, written under the lock")
	static var count = 0;

	public final id:Int;
	public final path:String;

	/** The declaration's name in its file, `Type.member` (with `#n` for the n-th repeat of a name), or "" for the whole file. */
	public final key:String;

	function new(id:Int, path:String, key:String) {
		this.id = id;
		this.path = path;
		this.key = key;
	}

	/** The anchor of declaration `key` of the file at `path`, made the first time it is asked for. */
	public static function of(path:String, key:String):SourceAnchor {
		lock.acquire();
		var inFile = byPath.get(path);
		if (inFile == null) {
			inFile = [];
			byPath.set(path, inFile);
		}
		var anchor = inFile.get(key);
		if (anchor == null) {
			var id = count, chunk = chunks[id >> CHUNK_BITS];
			if (chunk == null) {
				if (id >> CHUNK_BITS >= chunks.length) {
					lock.release();
					throw new InternalError('More than ${chunks.length * CHUNK_SIZE} source anchors');
				}
				chunk = [];
				chunk.resize(CHUNK_SIZE);
				chunks[id >> CHUNK_BITS] = chunk;
			}
			anchor = new SourceAnchor(id, path, key);
			chunk[id & (CHUNK_SIZE - 1)] = anchor;
			inFile.set(key, anchor);
			count = id + 1;
		}
		lock.release();
		return anchor;
	}

	/** The anchor with id `id`, which must be one `of` has given. */
	public static function at(id:Int):SourceAnchor {
		var chunk = id < 0 ? null : chunks[id >> CHUNK_BITS];
		if (chunk == null)
			throw new InternalError('No source anchor $id');
		return chunk[id & (CHUNK_SIZE - 1)];
	}

	/** The anchor of the whole file at `path`, from which positions count as they do in the file. */
	public static inline function file(path:String):Int
		return of(path, "").id;
}

/**
 * Where a build's sources put each anchor: its file, the offset and line it starts at, and the content hash of the file's text,
 * which names the snapshot a module carries of it. The files are the build's modules: whatever lowers IR made from modules by
 * itself (a test of a compiler's output, the stateless backend) passes the compiler's (`Compiler.sourceAnchors`). An anchor no
 * text places any more is where the session last placed it (`SourceAnchorHistory`): a live module keeps the code of functions an
 * edit removed. An anchor of the whole file of anything else (generated code) starts at offset 0 on line 1 and has no snapshot.
 */
@:nullSafety(Strict)
class SourceAnchors {
	final files:Map<String, SourceFile>;
	final history:Null<SourceAnchorHistory>;

	/** By anchor id, what is known of it: its offset, its line and its file's hash; -1 offsets for an anchor not looked up yet. */
	final offsets:Array<Int> = [];

	final lines:Array<Int> = [];
	final hashes:Array<Int> = [];

	public function new(files:Map<String, SourceFile>, ?history:SourceAnchorHistory) {
		this.files = files;
		this.history = history;
	}

	/** Whether `anchor` has a place: in the build's sources, or where the session last placed it. */
	public function places(anchor:Int):Bool {
		var entry = SourceAnchor.at(anchor), file = files.get(entry.path), known = history;
		return (file == null ? entry.key == "" : file.anchorIndex(anchor) != SourceFile.NO_ANCHOR)
			|| known != null && known.knows(anchor);
	}

	/** An anchor's file. */
	public inline function path(anchor:Int):String
		return SourceAnchor.at(anchor).path;

	/** The byte offset in its file that an anchor's positions count from. */
	public inline function offset(anchor:Int):Int
		return anchor < offsets.length && offsets[anchor] >= 0 ? offsets[anchor] : find(anchor);

	/** The line an anchor's lines count from. */
	public inline function line(anchor:Int):Int {
		if (anchor >= offsets.length || offsets[anchor] < 0)
			find(anchor);
		return lines[anchor];
	}

	/** The content hash of an anchor's file, or 0 when the build has no snapshot of it. */
	public inline function hash(anchor:Int):Int {
		if (anchor >= offsets.length || offsets[anchor] < 0)
			find(anchor);
		return hashes[anchor];
	}

	function find(anchor:Int):Int {
		var entry = SourceAnchor.at(anchor), file = files.get(entry.path), offset = 0, line = 1, hash = 0;
		var index = file == null ? SourceFile.NO_ANCHOR : file.anchorIndex(anchor), known = history;
		if (file != null && index != SourceFile.NO_ANCHOR) {
			offset = file.anchorOffset(index);
			line = file.anchorLine(index);
			hash = file.contentHash();
			if (known != null)
				known.record(anchor, offset, line, hash);
		} else if (known != null && known.knows(anchor)) {
			offset = known.offset(anchor);
			line = known.line(anchor);
			hash = known.hash(anchor);
		} else if (file != null || entry.key != "")
			throw new InternalError('Source anchor "${entry.key}" is not a declaration of ${entry.path}');
		while (offsets.length <= anchor) {
			offsets.push(-1);
			lines.push(0);
			hashes.push(0);
		}
		offsets[anchor] = offset;
		lines[anchor] = line;
		hashes[anchor] = hash;
		return offset;
	}
}

/**
 * Where a session's builds last placed each anchor (`SourceAnchors`), by anchor id: the place of the code a live module keeps
 * after an edit removed its declaration, as the last text that had it put it.
 */
@:nullSafety(Strict)
class SourceAnchorHistory {
	final offsets:Array<Int> = [];
	final lines:Array<Int> = [];
	final hashes:Array<Int> = [];

	public function new() {}

	public function record(anchor:Int, offset:Int, line:Int, hash:Int):Void {
		while (offsets.length <= anchor) {
			offsets.push(-1);
			lines.push(0);
			hashes.push(0);
		}
		offsets[anchor] = offset;
		lines[anchor] = line;
		hashes[anchor] = hash;
	}

	public inline function knows(anchor:Int):Bool
		return anchor < offsets.length && offsets[anchor] >= 0;

	public inline function offset(anchor:Int):Int
		return offsets[anchor];

	public inline function line(anchor:Int):Int
		return lines[anchor];

	public inline function hash(anchor:Int):Int
		return hashes[anchor];
}
