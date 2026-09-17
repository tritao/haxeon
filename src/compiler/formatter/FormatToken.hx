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
		return token.kind == Newline || token.text.indexOf("\n") >= 0 || token.text.indexOf("\r") >= 0;
}
