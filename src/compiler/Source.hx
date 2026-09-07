package compiler;

/** Immutable source text and its diagnostic path for one compiler input. */
class SourceFile {
	public final path:String;
	public final text:String;

	final lineStarts:Array<Int>;

	public function new(path:String, text:String) {
		this.path = path;
		this.text = text;
		lineStarts = [0];
		for (index in 0...text.length)
			if (text.charCodeAt(index) == 10)
				lineStarts.push(index + 1);
	}

	public function span(start:Int, end:Int):SourceSpan
		return new SourceSpan(this, start, end);

	/** One-based line containing an offset, found without rescanning source text. */
	public function lineAt(offset:Int):Int {
		if (offset < 0 || offset > text.length)
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

	/** Stable FNV-1a identity of the UTF-8 source snapshot used for compilation. */
	public function contentHash():Int {
		var hash:Int = cast 0x811C9DC5;
		var bytes = haxe.io.Bytes.ofString(text);
		for (index in 0...bytes.length)
			hash = (hash ^ bytes.get(index)) * 16777619;
		return hash;
	}
}

/** Half-open byte/character range within a single {@link SourceFile}. */
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
