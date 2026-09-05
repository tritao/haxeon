package compiler;

import compiler.Source.SourceSpan;

enum TokenKind {
	Package;
	Import;
	Class;
	Extends;
	Public;
	Private;
	Static;
	Final;
	New;
	This;
	Void;
	Function;
	Var;
	Return;
	If;
	Else;
	While;
	TypeInt;
	TypeBool;
	TypeFloat;
	TypeString;
	Identifier;
	Integer;
	Float;
	StringLiteral;
	LeftParen;
	RightParen;
	LeftBrace;
	RightBrace;
	Colon;
	Semicolon;
	Comma;
	Dot;
	Assign;
	Plus;
	Minus;
	Star;
	Slash;
	Less;
	LessEqual;
	EqualEqual;
	Eof;
}

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
