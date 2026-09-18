package compiler.syntax;

import compiler.Source.SourceSpan;

/** Closed vocabulary emitted by the lexer and consumed by the parser. */
enum TokenKind {
	Package;
	Import;
	Typedef;
	Class;
	Interface;
	Enum;
	Extends;
	Implements;
	Public;
	Private;
	Static;
	Inline;
	Final;
	New;
	This;
	Void;
	Function;
	Var;
	Return;
	Throw;
	Try;
	Catch;
	If;
	Else;
	While;
	Do;
	For;
	In;
	Break;
	Continue;
	Switch;
	Case;
	Default;
	BoolTrue;
	BoolFalse;
	TypeInt;
	TypeBool;
	TypeFloat;
	TypeString;
	Identifier;
	Integer;
	Float;
	StringLiteral;
	RegexLiteral;
	LeftParen;
	RightParen;
	LeftBrace;
	RightBrace;
	Colon;
	Semicolon;
	Comma;
	Dot;
	Assign;
	PlusAssign;
	MinusAssign;
	StarAssign;
	SlashAssign;
	PercentAssign;
	AndAssign;
	OrAssign;
	XorAssign;
	Increment;
	Decrement;
	Plus;
	Minus;
	Arrow;
	Star;
	Slash;
	Percent;
	Less;
	Greater;
	LessEqual;
	GreaterEqual;
	EqualEqual;
	NotEqual;
	Not;
	BitNot;
	AndAnd;
	OrOr;
	Ampersand;
	Pipe;
	Caret;
	LeftBracket;
	RightBracket;
	Question;
	NullCoalesce;
	At;
	Dollar;
	Eof;
}

/** One lexical token retaining its original spelling and source location. */
class Token {
	public final kind:TokenKind;
	public final span:SourceSpan;
	final literalText:Null<String>;

	/**
		Token spelling is lazy for source-backed tokens. Punctuation is consumed
		by kind and should not force a substring allocation during lexing; names
		and literals still materialize their spelling when the parser asks for it.
	*/
	public var text(get, never):String;
	public var offset(get, never):Int;

	public function new(kind:TokenKind, text:Null<String>, span:SourceSpan) {
		this.kind = kind;
		this.span = span;
		this.literalText = text;
	}

	/** Creates a token whose spelling is read from its source span on demand. */
	public static function fromSource(kind:TokenKind, span:SourceSpan):Token
		return new Token(kind, null, span);

	function get_text():String
		return literalText == null ? span.file.slice(span.start, span.end) : literalText;

	inline function get_offset():Int
		return span.start;
}
