package compiler;

class SourceFile {
	public final path:String;
	public final text:String;

	public function new(path:String, text:String) {
		this.path = path;
		this.text = text;
	}

	public function span(start:Int, end:Int):SourceSpan
		return new SourceSpan(this, start, end);
}

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
