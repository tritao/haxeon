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

typedef UnresolvedName = {
	final kind:UnresolvedNameKind;
	final name:String;
}

/** Structured compiler feedback tied to an exact source span. */
class Diagnostic {
	public final code:String;
	public final message:String;
	public final severity:DiagnosticSeverity;
	public final span:SourceSpan;
	public final fixes:Array<DiagnosticFix>;
	public final unresolvedName:Null<UnresolvedName>;
	public final notes:Array<String> = [];

	public function new(code, message, span, ?severity = Error, ?fixes:Array<DiagnosticFix>,
			?unresolvedName:UnresolvedName) {
		// A name an import made ambiguous resolves to a marker that matches nothing, so whichever check rejects it first
		// reports the ambiguity instead, at its own span; the marker never reaches a message.
		var ambiguity = AmbiguousName.describe(message);
		this.code = ambiguity == null ? code : AmbiguousName.CODE;
		this.message = ambiguity == null ? message : ambiguity;
		this.span = span;
		this.unresolvedName = ambiguity == null ? unresolvedName : null;
		this.severity = severity;
		this.fixes = fixes == null ? [] : fixes;
	}

	public static function unresolved(code:String, kind:UnresolvedNameKind, name:String, span:SourceSpan):Diagnostic {
		var prefix = kind == UnresolvedNameKind.WantedModule ? "Missing" : "Unknown";
		return new Diagnostic(code, '$prefix $kind "$name"', span, null, null, {kind: kind, name: name});
	}

	/** Human-readable location with one-based line and column, not a byte offset. */
	public function format():String {
		var location = span.file.lineColumnAt(span.start);
		return '${span.file.path}:${location.line}:${location.column}: $code: $message';
	}
	public function formatNotes():String
		return [for (note in notes) '\n  help: $note'].join("");
}

/**
 * Exception wrapper used to propagate structured diagnostics internally: one, or, when typing recovered from errors in several
 * independent bodies, all of them (`diagnostics`), the first of which is `diagnostic`.
 */
class CompileError extends haxe.Exception {
	public final diagnostic:Diagnostic;

	/** Every diagnostic of the failure, `diagnostic` first. */
	public final diagnostics:Array<Diagnostic>;

	public function new(diagnostic:Diagnostic, ?others:Array<Diagnostic>) {
		super(diagnostic.message);
		this.diagnostic = diagnostic;
		this.diagnostics = others == null ? [diagnostic] : [diagnostic].concat(others);
	}

	/** Located, so an error nobody catches still says where it happened. */
	override public function toString():String
		return diagnostic.format();

	/** Every diagnostic, one per line. */
	public function formatAll():String
		return [for (item in diagnostics) item.format() + item.formatNotes()].join("\n");
}
