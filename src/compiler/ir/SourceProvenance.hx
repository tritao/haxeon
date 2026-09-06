package compiler.ir;

import compiler.Source.SourceSpan;

/** Stable source coordinates retained independently of a compiler source snapshot. */
class SourceLocation {
	public final path:String;
	public final start:Int;
	public final end:Int;
	public final line:Int;

	public function new(path:String, start:Int, end:Int, line:Int) {
		if (path == null || start < 0 || end < start || line < 1)
			throw "Invalid source location";
		this.path = path;
		this.start = start;
		this.end = end;
		this.line = line;
	}

	public static function fromSpan(span:SourceSpan):SourceLocation {
		return new SourceLocation(span.file.path, span.start, span.end, span.file.lineAt(span.start));
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
