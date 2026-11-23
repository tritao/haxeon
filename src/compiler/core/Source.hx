package compiler.core;

/** Immutable source text and its diagnostic path for one compiler input. */
class SourceFile {
	public final path:String;
	public final physicalPath:String;
	public final text:String;
	/** True only when the configured source loader resolved this file from its standard-library root. */
	public final isStandardLibrarySource:Bool;
	public final bytes:haxe.io.Bytes;

	final lineStarts:Array<Int>;
	final hash:Int;
	final secondHash:Int;

	public function new(path:String, text:String, isStandardLibrarySource:Bool = false, ?physicalPath:String) {
		this.path = path;
		this.physicalPath = physicalPath ?? path;
		this.text = text;
		this.isStandardLibrarySource = isStandardLibrarySource;
		bytes = haxe.io.Bytes.ofString(text);
		lineStarts = [0];
		var contentHash:Int = cast 0x811C9DC5;
		var second:Int = cast 0x2545F491;
		for (index in 0...bytes.length) {
			var code = bytes.get(index);
			contentHash = (contentHash ^ code) * 16777619;
			second = (((second << 5) | (second >>> 27)) ^ code) * (cast 0x85EBCA6B:Int);
			if (code == "\n".code)
				lineStarts.push(index + 1);
		}
		hash = contentHash;
		secondHash = second;
	}

	public function span(start:Int, end:Int):SourceSpan
		return new SourceSpan(this, start, end);

	/**
	 * The length in bytes of `text` when the source holds exactly it at byte `offset`, or -1 when it does not. Compares in place:
	 * an identifier, which is ASCII nearly always, costs no allocation.
	 */
	public function utf8LengthAt(offset:Int, text:String):Int {
		var length = text.length;
		for (index in 0...length)
			if (StringTools.fastCodeAt(text, index) >= 0x80) {
				var encoded = haxe.io.Bytes.ofString(text);
				return offset + encoded.length <= bytes.length
					&& bytes.sub(offset, encoded.length).compare(encoded) == 0 ? encoded.length : -1;
			}
		if (offset < 0 || offset + length > bytes.length)
			return -1;
		for (index in 0...length)
			if (bytes.get(offset + index) != StringTools.fastCodeAt(text, index))
				return -1;
		return length;
	}

	public function slice(start:Int, end:Int):String {
		if (start < 0 || end < start || end > bytes.length)
			throw new InternalError('Source range $start...$end is outside "$path"');
		return bytes.getString(start, end - start);
	}

	public function byteOffsetForStringOffset(offset:Int):Int {
		if (offset < 0 || offset > text.length)
			throw new InternalError("String offset is outside the source");
		var cursor = 0, characters = 0;
		while (characters < offset) {
			var width = utf8Width(bytes.get(cursor));
			characters += width == 4 ? 2 : 1;
			if (characters > offset)
				throw new InternalError("String offset splits a surrogate pair");
			cursor += width;
		}
		return cursor;
	}

	public function stringOffsetForByteOffset(offset:Int):Int {
		if (offset < 0 || offset > bytes.length)
			throw new InternalError("Byte offset is outside the source");
		var cursor = 0, characters = 0;
		while (cursor < offset) {
			var width = utf8Width(bytes.get(cursor));
			if (cursor + width > offset)
				throw new InternalError("Byte offset splits a UTF-8 sequence");
			characters += width == 4 ? 2 : 1;
			cursor += width;
		}
		return characters;
	}

	/** One-based line containing an offset, found without rescanning source text. */
	public function lineAt(offset:Int):Int {
		if (offset < 0 || offset > bytes.length)
			throw new InternalError('Source offset $offset is outside "$path"');
		var low = 0, high = lineStarts.length;
		while (low < high) {
			var middle = low + ((high - low) >> 1);
			if (lineStarts[middle] <= offset)
				low = middle + 1;
			else
				high = middle;
		}
		return low;
	}

	/** One-based column containing an offset. */
	public function columnAt(offset:Int):Int {
		var line = lineAt(offset);
		return offset - lineStarts[line - 1] + 1;
	}

	/** One-based column of an offset on a line already found with `lineAt`. */
	public inline function columnOnLine(offset:Int, line:Int):Int
		return offset - lineStarts[line - 1] + 1;

	/** One-based line and column containing an offset, using a single line lookup. */
	public function lineColumnAt(offset:Int):{line:Int, column:Int} {
		var line = lineAt(offset);
		return {line: line, column: offset - lineStarts[line - 1] + 1};
	}

	/** Convert a zero-based LSP UTF-16 position to the compiler's UTF-8 byte offset. */
	public function byteOffsetAt(line:Int, character:Int):Int {
		if (line < 0 || character < 0 || line >= lineStarts.length)
			throw new InternalError("LSP position is outside the source");
		var offset = lineStarts[line], end = lineEnd(line), units = 0;
		while (offset < end && units < character) {
			var code = bytes.get(offset),
				width = utf8Width(code),
				utf16 = width == 4 ? 2 : 1;
			if (units + utf16 > character)
				throw new InternalError("LSP position splits a UTF-16 surrogate pair");
			units += utf16;
			offset += width;
		}
		if (units != character)
			throw new InternalError("LSP position is outside the source");
		return offset;
	}

	/** Convert a compiler UTF-8 byte offset to a zero-based LSP UTF-16 position. */
	public function lspPosition(offset:Int):{line:Int, character:Int} {
		var line = lineAt(offset) - 1, cursor = lineStarts[line], units = 0;
		while (cursor < offset) {
			var width = utf8Width(bytes.get(cursor));
			if (cursor + width > offset)
				throw new InternalError("Compiler position splits a UTF-8 sequence");
			units += width == 4 ? 2 : 1;
			cursor += width;
		}
		return {line: line, character: units};
	}

	function lineEnd(line:Int):Int {
		var end = line + 1 < lineStarts.length ? lineStarts[line + 1] - 1 : bytes.length;
		if (end > lineStarts[line] && bytes.get(end - 1) == "\r".code)
			end--;
		return end;
	}

	static inline function utf8Width(code:Int):Int
		return code < 0x80 ? 1 : code < 0xE0 ? 2 : code < 0xF0 ? 3 : 4;

	/** The same identity as `strongHash` for bytes that are not a source file. */
	public static function hashBytes(bytes:haxe.io.Bytes):String {
		var first:Int = cast 0x811C9DC5, second:Int = cast 0x2545F491;
		for (index in 0...bytes.length) {
			var code = bytes.get(index);
			first = (first ^ code) * 16777619;
			second = (((second << 5) | (second >>> 27)) ^ code) * (cast 0x85EBCA6B:Int);
		}
		return StringTools.hex(first, 8) + StringTools.hex(second, 8) + "-" + bytes.length;
	}

	/**
	 * A 64-bit identity of the source bytes (two independent 32-bit hashes) plus their length, as text. Strong enough to tell
	 * two edits of one file apart for cache keys; `contentHash` alone (32 bits) is not.
	 */
	public function strongHash():String
		return StringTools.hex(hash, 8) + StringTools.hex(secondHash, 8) + "-" + bytes.length;

	/** Stable FNV-1a identity of the UTF-8 source snapshot used for compilation. */
	public function contentHash():Int
		return hash;
}

/**
 * Half-open UTF-8 byte range within a single {@link SourceFile}. Most spans are only that; the parser's reference spans
 * also carry what was written at the reference ({@link ReferenceSpan}).
 */
class SourceSpan {
	public final file:SourceFile;
	public final start:Int;
	public final end:Int;

	/** Parser-recorded qualification for a variable or named call reference. */
	public var isBareReference(get, never):Bool;

	/** Original reference path before module or import expansion; introduced package roots are not value bindings. */
	public var referenceName(get, never):Null<String>;

	/** Compiler-owned syntax has no user source snapshot. */
	public var generatedReason(get, never):Null<String>;

	public function new(file:SourceFile, start:Int, end:Int) {
		this.file = file;
		this.start = start;
		this.end = end;
	}

	/**
	 * A span of a reference: a plain span unless the reference is bare or has a name recorded. Most references are bare
	 * names with nothing recorded, so those get a span of their own class with no extra fields.
	 */
	public static function reference(file:SourceFile, start:Int, end:Int, isBareReference:Bool,
			?referenceName:String):SourceSpan
		return referenceName != null ? new ReferenceSpan(file, start, end, isBareReference,
			referenceName) : isBareReference ? new BareReferenceSpan(file, start, end) : new SourceSpan(file, start,
			end);

	function get_isBareReference():Bool
		return false;

	function get_referenceName():Null<String>
		return null;

	function get_generatedReason():Null<String>
		return null;

	public static function generated(reason:String):SourceSpan
		return new GeneratedSpan(new SourceFile("<generated:" + reason + ">", ""), 0, 0, reason);

	/** A span of compiler-owned code placed in `file`, made for `reason`. */
	public static function generatedIn(file:SourceFile, start:Int, end:Int, reason:String):SourceSpan
		return new GeneratedSpan(file, start, end, reason);

	/** The range covering both spans, in this one's file; it stays generated only when both were, for the same reason. */
	public function merge(other:SourceSpan):SourceSpan {
		var start = this.start < other.start ? this.start : other.start,
			end = this.end > other.end ? this.end : other.end,
			reason = generatedReason;
		return reason != null && reason == other.generatedReason ? new GeneratedSpan(file, start, end,
			reason) : new SourceSpan(file, start, end);
	}
}

/** A span of compiler-owned syntax, with the reason it was made. */
class GeneratedSpan extends SourceSpan {
	final reason:String;

	public function new(file:SourceFile, start:Int, end:Int, reason:String) {
		super(file, start, end);
		this.reason = reason;
	}

	override function get_generatedReason():Null<String>
		return reason;
}

/** The span of a bare reference with no name recorded. */
class BareReferenceSpan extends SourceSpan {
	override function get_isBareReference():Bool
		return true;
}

/** A reference's span, with the name the canonicalizer recorded and whether the parser saw it bare. */
class ReferenceSpan extends SourceSpan {
	final bare:Bool;
	final written:String;

	public function new(file:SourceFile, start:Int, end:Int, bare:Bool, written:String) {
		super(file, start, end);
		this.bare = bare;
		this.written = written;
	}

	override function get_isBareReference():Bool
		return bare;

	override function get_referenceName():Null<String>
		return written;
}
