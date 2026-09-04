package compiler;

import compiler.Source.SourceSpan;

enum DiagnosticSeverity {
	Error;
	Warning;
}

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

class CompileError extends haxe.Exception {
	public final diagnostic:Diagnostic;

	public function new(diagnostic:Diagnostic) {
		this.diagnostic = diagnostic;
		super(diagnostic.message);
	}
}
