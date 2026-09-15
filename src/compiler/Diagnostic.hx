package compiler;

import compiler.Source.SourceSpan;

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

/** Provenance used to keep editor diagnostics explainable across snapshots. */
enum abstract DiagnosticOrigin(String) {
	var Lexical = "lexical";
	var ParserRecovery = "parser-recovery";
	var Semantic = "semantic";
	var Stale = "stale";
}

/** Structured compiler feedback tied to an exact source span. */
class Diagnostic {
	public final code:String;
	public final message:String;
	public final severity:DiagnosticSeverity;
	public final span:SourceSpan;
	public final fixes:Array<DiagnosticFix>;
	public var origin:DiagnosticOrigin;

	public function new(code, message, span, ?severity = Error, ?fixes:Array<DiagnosticFix>, ?origin:DiagnosticOrigin = Semantic) {
		this.code = code;
		this.message = message;
		this.span = span;
		this.severity = severity;
		this.fixes = fixes == null ? [] : fixes;
		this.origin = origin;
	}

	/**
	 * Renders this diagnostic as `file:line:column: CODE: message`.
	 *
	 * A span carries a byte offset, which is meaningless to a reader: the offset
	 * is resolved through the source so the printed position can be opened
	 * directly. An offset that cannot be resolved keeps the raw value instead of
	 * throwing while a failure is already being reported.
	 */
	public function displayMessage():String {
		var position = try {
			var resolved = span.file.lineColumnAt(span.start);
			resolved.line + ":" + resolved.column;
		} catch (_:Dynamic) {
			Std.string(span.start);
		}
		return span.file.path + ":" + position + ": " + code + ": " + message;
	}
}

/** Exception wrapper used to propagate one structured diagnostic internally. */
class CompileError {
	public final diagnostic:Diagnostic;

	public function new(diagnostic:Diagnostic) {
		this.diagnostic = diagnostic;
	}

	public function toString():String
		return diagnostic.message;
}
