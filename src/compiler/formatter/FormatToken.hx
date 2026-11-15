package compiler.formatter;

import compiler.syntax.Token.TokenKind;

/** Token kinds used by the formatter's lossless source representation. */
enum FormatTokenKind {
	Syntax(kind:TokenKind);
	Whitespace;
	Newline;
	LineComment;
	BlockComment;
	DocComment;
	Directive;
	FormatterOff;
}

/** A formatter token whose span is measured in UTF-8 source bytes. */
typedef FormatToken = {
	final kind:FormatTokenKind;
	final text:String;
	final start:Int;
	final end:Int;
}

class FormatTokenTools {
	/** The index of the nearest code token before `index`, or -1: comments, whitespace and line breaks are skipped. */
	public static function previousSyntax(tokens:Array<FormatToken>, index:Int):Int {
		var previous = index - 1;
		while (previous >= 0 && !isSyntax(tokens[previous]))
			previous--;
		return previous;
	}

	/** The index of the nearest code token after `index`, or -1. */
	public static function nextSyntax(tokens:Array<FormatToken>, index:Int):Int {
		var next = index + 1;
		while (next < tokens.length && !isSyntax(tokens[next]))
			next++;
		return next < tokens.length ? next : -1;
	}

	public static function isSyntax(token:FormatToken):Bool
		return switch token.kind {
			case Syntax(_): true;
			default: false;
		};

	public static function syntaxKind(token:FormatToken):Null<TokenKind>
		return switch token.kind {
			case Syntax(kind): kind;
			default: null;
		};

	public static function hasNewline(token:FormatToken):Bool
		return token.kind.match(Newline) || token.text.indexOf("\n") >= 0 || token.text.indexOf("\r") >= 0;
}
