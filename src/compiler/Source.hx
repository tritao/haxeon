package compiler;

/** Immutable source text and its diagnostic path for one compiler input. */
class SourceFile {
	public final path:String;
	public final text:String;
	public final bytes:haxe.io.Bytes;

	final lineStarts:Array<Int>;
	final hash:Int;

	public function new(path:String, text:String) {
		this.path = path;
		this.text = text;
		bytes = haxe.io.Bytes.ofString(text);
		lineStarts = [0];
		var contentHash:Int = cast 0x811C9DC5;
		for (index in 0...bytes.length) {
			var code = bytes.get(index);
			contentHash = (contentHash ^ code) * 16777619;
			if (code == "\n".code)
				lineStarts.push(index + 1);
		}
		hash = contentHash;
	}

	public function span(start:Int, end:Int):SourceSpan
		return new SourceSpan(this, start, end);

	public function slice(start:Int, end:Int):String {
		if (start < 0 || end < start || end > bytes.length)
			throw 'Source range $start...$end is outside "$path"';
		return bytes.getString(start, end - start);
	}

	public function byteOffsetForStringOffset(offset:Int):Int {
		if (offset < 0 || offset > text.length)
			throw "String offset is outside the source";
		var cursor = 0, characters = 0;
		while (characters < offset) {
			var width = utf8Width(bytes.get(cursor));
			characters += width == 4 ? 2 : 1;
			if (characters > offset)
				throw "String offset splits a surrogate pair";
			cursor += width;
		}
		return cursor;
	}

	public function stringOffsetForByteOffset(offset:Int):Int {
		if (offset < 0 || offset > bytes.length)
			throw "Byte offset is outside the source";
		var cursor = 0, characters = 0;
		while (cursor < offset) {
			var width = utf8Width(bytes.get(cursor));
			if (cursor + width > offset)
				throw "Byte offset splits a UTF-8 sequence";
			characters += width == 4 ? 2 : 1;
			cursor += width;
		}
		return characters;
	}

	/** One-based line containing an offset, found without rescanning source text. */
	public function lineAt(offset:Int):Int {
		if (offset < 0 || offset > bytes.length)
			throw 'Source offset $offset is outside "$path"';
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

	/** Convert a zero-based LSP UTF-16 position to the compiler's UTF-8 byte offset. */
	public function byteOffsetAt(line:Int, character:Int):Int {
		if (line < 0 || character < 0 || line >= lineStarts.length)
			throw "LSP position is outside the source";
		var offset = lineStarts[line], end = lineEnd(line), units = 0;
		while (offset < end && units < character) {
			var code = bytes.get(offset), width = utf8Width(code), utf16 = width == 4 ? 2 : 1;
			if (units + utf16 > character)
				throw "LSP position splits a UTF-16 surrogate pair";
			units += utf16;
			offset += width;
		}
		if (units != character)
			throw "LSP position is outside the source";
		return offset;
	}

	/** Convert a compiler UTF-8 byte offset to a zero-based LSP UTF-16 position. */
	public function lspPosition(offset:Int):{line:Int, character:Int} {
		var line = lineAt(offset) - 1, cursor = lineStarts[line], units = 0;
		while (cursor < offset) {
			var width = utf8Width(bytes.get(cursor));
			if (cursor + width > offset)
				throw "Compiler position splits a UTF-8 sequence";
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

	/** Stable FNV-1a identity of the UTF-8 source snapshot used for compilation. */
	public function contentHash():Int
		return hash;
}

/** Half-open UTF-8 byte range within a single {@link SourceFile}. */
class SourceSpan {
	public final file:SourceFile;
	public final start:Int;
	public final end:Int;

	public function new(file:SourceFile, start:Int, end:Int) {
		this.file = file;
		this.start = start;
		this.end = end;
	}

	public function merge(other:SourceSpan):SourceSpan
		return new SourceSpan(file, start < other.start ? start : other.start, end > other.end ? end : other.end);
}
