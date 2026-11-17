package compiler.core;

import compiler.core.Source.SourceSpan;

typedef DiagnosticEdit = {
	final span:SourceSpan;
	final replacement:String;
}

/** Compiler-authored deterministic repair attached to a diagnostic. */
typedef DiagnosticFix = {
	final id:String;
	final title:String;
	final edits:Array<DiagnosticEdit>;
}

/** User-facing importance assigned to a compiler diagnostic. */
enum DiagnosticSeverity {
	Error;
	Warning;
}

/** Structured compiler feedback tied to an exact source span. */
class Diagnostic {
	public final code:String;
	public final message:String;
	public final severity:DiagnosticSeverity;
	public final span:SourceSpan;
	public final fixes:Array<DiagnosticFix>;

	public function new(code, message, span, ?severity = Error, ?fixes:Array<DiagnosticFix>) {
		// A name an import made ambiguous resolves to a marker that matches nothing, so whichever check rejects it first
		// reports the ambiguity instead, at its own span; the marker never reaches a message.
		var ambiguity = AmbiguousName.describe(message);
		this.code = ambiguity == null ? code : AmbiguousName.CODE;
		this.message = ambiguity == null ? message : ambiguity;
		this.span = span;
		this.severity = severity;
		this.fixes = fixes == null ? [] : fixes;
	}

	/** Human-readable location with one-based line and column, not a byte offset. */
	public function format():String {
		var location = span.file.lineColumnAt(span.start);
		return '${span.file.path}:${location.line}:${location.column}: $code: $message';
	}
}

/**
 * Exception wrapper used to propagate structured diagnostics internally: one, or, when typing recovered from errors in several
 * independent bodies, all of them (`diagnostics`), the first of which is `diagnostic`.
 */
class CompileError {
	public final diagnostic:Diagnostic;

	/** Every diagnostic of the failure, `diagnostic` first. */
	public final diagnostics:Array<Diagnostic>;

	public function new(diagnostic:Diagnostic, ?others:Array<Diagnostic>) {
		this.diagnostic = diagnostic;
		this.diagnostics = others == null ? [diagnostic] : [diagnostic].concat(others);
	}

	/** Located, so an error nobody catches still says where it happened. */
	public function toString():String
		return diagnostic.format();

	/** Every diagnostic, one per line. */
	public function formatAll():String
		return [for (item in diagnostics) item.format()].join("\n");
}
