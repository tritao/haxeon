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

/** Structured compiler feedback tied to an exact source span. */
class Diagnostic {
	public final code:String;
	public final message:String;
	public final severity:DiagnosticSeverity;
	public final span:SourceSpan;
	public final fixes:Array<DiagnosticFix>;

	public function new(code, message, span, ?severity = Error, ?fixes:Array<DiagnosticFix>) {
		this.code = code;
		this.message = message;
		this.span = span;
		this.severity = severity;
		this.fixes = fixes == null ? [] : fixes;
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
