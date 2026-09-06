package compiler;

import compiler.Source.SourceSpan;

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

	public function new(code, message, span, ?severity = Error) {
		this.code = code;
		this.message = message;
		this.span = span;
		this.severity = severity;
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
