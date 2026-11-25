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
	@:processWide("interned anchors: a path and name always denote the same anchor, and the table only grows")
	static final byName:Map<String, SourceAnchor> = [];

	@:processWide("guards interning, which the parse threads and the compile thread may both do")
	static final lock = new Mutex();

	static inline final CHUNK_BITS = 12;
	static inline final CHUNK_SIZE = 1 << CHUNK_BITS;

	/** The anchors by id, in chunks that never move once made, so `at` needs no lock (as `IrSymbol` keeps its symbols). */
	@:processWide("interned anchors, by id: the chunks only fill")
	static final chunks:Array<Null<Array<SourceAnchor>>> = [for (_ in 0...1 << 14) null];

	@:processWide("how many anchors are interned, written under the lock")
	static var count = 0;

	/**
	 * By path, the text whose parse last declared the file's anchors: where a lowering given no build's sources places them (a
	 * test, the stateless backend). A build always places them in its own sources.
	 */
	@:processWide("the last parsed text of each path, read only by a lowering given no build's sources, written under the lock")
	static final declaredFiles:Map<String, SourceFile> = [];

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
		var name = path + "\n" + key;
		lock.acquire();
		var anchor = byName.get(name);
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
			byName.set(name, anchor);
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

	/** Records that `file`'s parse declared its anchors (`declaredFile`). */
	public static function declared(file:SourceFile):Void {
		lock.acquire();
		declaredFiles.set(file.path, file);
		lock.release();
	}

	/** The text whose parse last declared the anchors of `path`, if any did. */
	public static function declaredFile(path:String):Null<SourceFile> {
		lock.acquire();
		var file = declaredFiles.get(path);
		lock.release();
		return file;
	}

	/** The anchor of the whole file at `path`, from which positions count as they do in the file. */
	public static inline function file(path:String):Int
		return of(path, "").id;
}

/**
 * Where a build's sources put each anchor: its file, the offset and line it starts at, and the content hash of the file's text,
 * which names the snapshot a module carries of it. The files are the build's modules; without one at an anchor's path, the text
 * that last declared its anchors (`SourceAnchor.declaredFile`), for a lowering made without a build. An anchor of the whole file
 * of anything else (generated code) starts at offset 0 on line 1 and has no snapshot.
 */
@:nullSafety(Strict)
class SourceAnchors {
	final files:Map<String, SourceFile>;

	/** By anchor id, what is known of it: its offset, its line and its file's hash; -1 offsets for an anchor not looked up yet. */
	final offsets:Array<Int> = [];

	final lines:Array<Int> = [];
	final hashes:Array<Int> = [];

	public function new(files:Map<String, SourceFile>)
		this.files = files;

	/** Whether the build's sources place `anchor`, which a declaration that is gone does not. */
	public function places(anchor:Int):Bool {
		var entry = SourceAnchor.at(anchor), file = fileAt(entry.path);
		return file == null ? entry.key == "" : file.anchorIndex(anchor) != SourceFile.NO_ANCHOR;
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

	function fileAt(path:String):Null<SourceFile>
		return files.get(path) ?? SourceAnchor.declaredFile(path);

	function find(anchor:Int):Int {
		var entry = SourceAnchor.at(anchor), file = fileAt(entry.path), offset = 0, line = 1, hash = 0;
		if (file != null) {
			hash = file.contentHash();
			var index = file.anchorIndex(anchor);
			if (index == SourceFile.NO_ANCHOR)
				throw new InternalError('Source anchor "${entry.key}" is not a declaration of ${entry.path}');
			offset = file.anchorOffset(index);
			line = file.anchorLine(index);
		} else if (entry.key != "")
			throw new InternalError('Source anchor "${entry.key}" names ${entry.path}, which nothing parsed');
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
