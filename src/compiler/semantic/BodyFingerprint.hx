package compiler.semantic;

import compiler.core.Source.SourceFile;

/**
 * What a function body's change detection compares (`ModuleChangeAnalyzer`): its file's path, its line, its offset for a
 * generic function, and its source text, read in place from its file rather than copied out. It keeps that file alive
 * until the next analysis replaces it.
 */
class BodyFingerprint {
	final file:SourceFile;
	final line:Int;
	final offset:Int;
	final start:Int;
	final end:Int;

	/** `offset` is -1 when the offset is not part of the identity. */
	public function new(file:SourceFile, start:Int, end:Int, offset:Int) {
		this.file = file;
		this.start = start;
		this.end = end;
		this.offset = offset;
		line = file.lineAt(start);
	}

	public function equals(other:Null<BodyFingerprint>):Bool {
		if (other == null || other.line != line || other.offset != offset || other.end - other.start != end - start
			|| other.file.path != file.path)
			return false;
		if (other.file == file && other.start == start)
			return true;
		var bytes = file.bytes, otherBytes = other.file.bytes;
		for (index in 0...end - start)
			if (bytes.get(start + index) != otherBytes.get(other.start + index))
				return false;
		return true;
	}
}
