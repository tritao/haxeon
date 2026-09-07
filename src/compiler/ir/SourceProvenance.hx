package compiler.ir;

import compiler.Source.SourceSpan;

/** Stable source coordinates retained independently of a compiler source snapshot. */
class SourceLocation {
	public final path:String;
	public final start:Int;
	public final end:Int;
	public final line:Int;
	public final column:Int;
	public final endLine:Int;
	public final endColumn:Int;
	public final sourceHash:Int;

	public function new(path:String, start:Int, end:Int, line:Int, column:Int = 1, ?endLine:Int, ?endColumn:Int, sourceHash:Int = 0) {
		this.endLine = endLine == null ? line : endLine;
		this.endColumn = endColumn == null ? column : endColumn;
		if (path == null || start < 0 || end < start || line < 1 || column < 1 || this.endLine < line || this.endColumn < 1
			|| this.endLine == line && this.endColumn < column)
			throw "Invalid source location";
		this.path = path;
		this.start = start;
		this.end = end;
		this.line = line;
		this.column = column;
		this.sourceHash = sourceHash;
	}

	public static function fromSpan(span:SourceSpan):SourceLocation {
		return new SourceLocation(span.file.path, span.start, span.end, span.file.lineAt(span.start), span.file.columnAt(span.start),
			span.file.lineAt(span.end), span.file.columnAt(span.end), span.file.contentHash());
	}
}

/** Why an operation exists when it is not a direct translation of source syntax. */
enum SourceOrigin {
	UserSource;
	CompilerGenerated(reason:String);
}

/** Source ownership carried by CFG and SSA operations through transformations. */
class SourceProvenance {
	public final location:Null<SourceLocation>;
	public final origin:SourceOrigin;

	public function new(location:Null<SourceLocation>, origin:SourceOrigin) {
		if (location == null)
			switch origin {
				case UserSource:
					throw "User-source provenance requires a location";
				case CompilerGenerated(_):
			}
		this.location = location;
		this.origin = origin;
	}

	public static function user(span:SourceSpan):SourceProvenance
		return new SourceProvenance(SourceLocation.fromSpan(span), UserSource);

	public static function generated(reason:String, ?anchor:SourceSpan):SourceProvenance
		return new SourceProvenance(anchor == null ? null : SourceLocation.fromSpan(anchor), CompilerGenerated(reason));
}

/** Keeps transformation provenance structurally attached to an operation. */
class Located<T> {
	public final value:T;
	public final provenance:SourceProvenance;

	public function new(value:T, provenance:SourceProvenance) {
		if (provenance == null)
			throw "Located operation requires provenance";
		this.value = value;
		this.provenance = provenance;
	}
}
