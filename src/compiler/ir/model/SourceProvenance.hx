package compiler.ir.model;

import compiler.core.InternalError;
import compiler.core.Source.SourceSpan;

/**
 * Where an operation's source is, counted from its anchor (`SourceAnchor`): the member declaration the position lies in, or the
 * whole file. Offsets and lines are distances from the anchor's start and the line it starts on; columns are the file's. So a
 * location says nothing about where its declaration sits in the file, and text moved above the declaration changes no function;
 * whatever writes positions out finds the anchor in its build's sources (`SourceAnchors`).
 */
@:nullSafety(Strict)
class SourceLocation {
	public final anchor:Int;
	public final start:Int;
	public final end:Int;
	public final line:Int;
	public final column:Int;
	public final endLine:Int;
	public final endColumn:Int;

	/** Whether the span is text the compiler wrote, which no snapshot of the file holds. */
	public final generatedText:Bool;

	public function new(anchor:Int, start:Int, end:Int, line:Int, column:Int, endLine:Int, endColumn:Int,
			generatedText:Bool) {
		if (anchor < 0 || start < 0 || end < start || line < 0 || column < 1 || endLine < line || endColumn < 1
			|| endLine == line && endColumn < column)
			throw new InternalError("Invalid source location");
		this.anchor = anchor;
		this.start = start;
		this.end = end;
		this.line = line;
		this.column = column;
		this.endLine = endLine;
		this.endColumn = endColumn;
		this.generatedText = generatedText;
	}

	public static function fromSpan(span:SourceSpan):SourceLocation {
		var file = span.file,
			index = file.anchorAt(span.start),
			offset = file.anchorOffset(index),
			line = file.anchorLine(index),
			startLine = file.lineAt(span.start),
			endLine = file.lineAt(span.end);
		return new SourceLocation(file.anchorId(index), span.start - offset, span.end - offset, startLine - line,
			file.columnOnLine(span.start, startLine), endLine - line, file.columnOnLine(span.end, endLine),
			span.generatedReason != null);
	}

	/** Whether this is where `span` is. */
	public function isAt(span:SourceSpan):Bool {
		if (end - start != span.end - span.start || generatedText != (span.generatedReason != null))
			return false;
		var file = span.file, index = file.anchorAt(span.start), offset = file.anchorOffset(index);
		return anchor == file.anchorId(index) && start == span.start - offset;
	}
}

/** Why an operation exists when it is not a direct translation of source syntax. */
enum SourceOrigin {
	UserSource;
	CompilerGenerated(reason:String);
}

/** Source ownership carried by CFG and SSA operations through transformations. */
@:nullSafety(Strict)
class SourceProvenance {
	public final location:Null<SourceLocation>;
	public final origin:SourceOrigin;

	public function new(location:Null<SourceLocation>, origin:SourceOrigin) {
		if (location == null)
			switch origin {
				case UserSource:
					throw new InternalError("User-source provenance requires a location");
				case CompilerGenerated(_):
			}
		this.location = location;
		this.origin = origin;
	}

	public static function user(span:SourceSpan):SourceProvenance {
		var reason = span.generatedReason;
		return new SourceProvenance(SourceLocation.fromSpan(span),
			reason == null ? UserSource : CompilerGenerated(reason));
	}

	public static function generated(reason:String, ?anchor:SourceSpan):SourceProvenance
		return new SourceProvenance(anchor == null ? null : SourceLocation.fromSpan(anchor), CompilerGenerated(reason));
}

/** Keeps transformation provenance structurally attached to an operation. */
@:nullSafety(Strict)
class Located<T> {
	public final value:T;
	public final provenance:SourceProvenance;

	public function new(value:T, provenance:SourceProvenance) {
		if (provenance == null)
			throw new InternalError("Located operation requires provenance");
		this.value = value;
		this.provenance = provenance;
	}
}
