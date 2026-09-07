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
	AndAnd;
	OrOr;
	Ampersand;
	Pipe;
	Caret;
	LeftBracket;
	RightBracket;
	Question;
	At;
	Eof;
}

/** One lexical token retaining its original spelling and source location. */
class Token {
	public final kind:TokenKind;
	public final text:String;
	public final span:SourceSpan;
	public var offset(get, never):Int;

	public function new(kind:TokenKind, text:String, span:SourceSpan) {
		this.kind = kind;
		this.text = text;
		this.span = span;
	}

	inline function get_offset():Int
		return span.start;
}
