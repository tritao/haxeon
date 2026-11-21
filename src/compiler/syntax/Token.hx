package compiler.syntax;

import compiler.core.Source.SourceSpan;

/**
 * Closed vocabulary emitted by the lexer and consumed by the parser. A kind is a small integer, so a file's kinds are a
 * plain `Int` column of its `TokenTable`.
 */
enum abstract TokenKind(Int) {
	var Package = 0;
	var Import = 1;
	var Typedef = 2;
	var Class = 3;
	var Struct = 4;
	var Interface = 5;
	var Enum = 6;
	var Extends = 7;
	var Implements = 8;
	var Public = 9;
	var Private = 10;
	var Static = 11;
	var Inline = 12;
	var Final = 13;
	var New = 14;
	var This = 15;
	var Void = 16;
	var Function = 17;
	var Var = 18;
	var Return = 19;
	var Defer = 20;
	var Throw = 21;
	var Try = 22;
	var Catch = 23;
	var If = 24;
	var Else = 25;
	var While = 26;
	var Do = 27;
	var For = 28;
	var In = 29;
	var Break = 30;
	var Continue = 31;
	var Switch = 32;
	var Case = 33;
	var Default = 34;
	var BoolTrue = 35;
	var BoolFalse = 36;
	var TypeInt = 37;
	var TypeBool = 38;
	var TypeFloat = 39;
	var TypeString = 40;
	var Identifier = 41;
	var Integer = 42;
	var Float = 43;
	var StringLiteral = 44;
	var RegexLiteral = 45;
	var LeftParen = 46;
	var RightParen = 47;
	var LeftBrace = 48;
	var RightBrace = 49;
	var Colon = 50;
	var Semicolon = 51;
	var Comma = 52;
	var Dot = 53;
	var Assign = 54;
	var PlusAssign = 55;
	var MinusAssign = 56;
	var StarAssign = 57;
	var SlashAssign = 58;
	var PercentAssign = 59;
	var AndAssign = 60;
	var OrAssign = 61;
	var XorAssign = 62;
	var Increment = 63;
	var Decrement = 64;
	var Plus = 65;
	var Minus = 66;
	var Arrow = 67;
	var Star = 68;
	var Slash = 69;
	var Backslash = 70;
	var Percent = 71;
	var Less = 72;
	var Greater = 73;
	var LessEqual = 74;
	var GreaterEqual = 75;
	var EqualEqual = 76;
	var NotEqual = 77;
	var Not = 78;
	var BitNot = 79;
	var AndAnd = 80;
	var OrOr = 81;
	var Ampersand = 82;
	var Pipe = 83;
	var Caret = 84;
	var LeftBracket = 85;
	var RightBracket = 86;
	var Question = 87;
	var NullCoalesce = 88;
	var At = 89;
	var Dollar = 90;
	var Eof = 91;

	/** The kind's name, as messages and token dumps spell it. */
	public function toString():String
		return switch (cast this:TokenKind) {
			case Package: "Package";
			case Import: "Import";
			case Typedef: "Typedef";
			case Class: "Class";
			case Struct: "Struct";
			case Interface: "Interface";
			case Enum: "Enum";
			case Extends: "Extends";
			case Implements: "Implements";
			case Public: "Public";
			case Private: "Private";
			case Static: "Static";
			case Inline: "Inline";
			case Final: "Final";
			case New: "New";
			case This: "This";
			case Void: "Void";
			case Function: "Function";
			case Var: "Var";
			case Return: "Return";
			case Defer: "Defer";
			case Throw: "Throw";
			case Try: "Try";
			case Catch: "Catch";
			case If: "If";
			case Else: "Else";
			case While: "While";
			case Do: "Do";
			case For: "For";
			case In: "In";
			case Break: "Break";
			case Continue: "Continue";
			case Switch: "Switch";
			case Case: "Case";
			case Default: "Default";
			case BoolTrue: "BoolTrue";
			case BoolFalse: "BoolFalse";
			case TypeInt: "TypeInt";
			case TypeBool: "TypeBool";
			case TypeFloat: "TypeFloat";
			case TypeString: "TypeString";
			case Identifier: "Identifier";
			case Integer: "Integer";
			case Float: "Float";
			case StringLiteral: "StringLiteral";
			case RegexLiteral: "RegexLiteral";
			case LeftParen: "LeftParen";
			case RightParen: "RightParen";
			case LeftBrace: "LeftBrace";
			case RightBrace: "RightBrace";
			case Colon: "Colon";
			case Semicolon: "Semicolon";
			case Comma: "Comma";
			case Dot: "Dot";
			case Assign: "Assign";
			case PlusAssign: "PlusAssign";
			case MinusAssign: "MinusAssign";
			case StarAssign: "StarAssign";
			case SlashAssign: "SlashAssign";
			case PercentAssign: "PercentAssign";
			case AndAssign: "AndAssign";
			case OrAssign: "OrAssign";
			case XorAssign: "XorAssign";
			case Increment: "Increment";
			case Decrement: "Decrement";
			case Plus: "Plus";
			case Minus: "Minus";
			case Arrow: "Arrow";
			case Star: "Star";
			case Slash: "Slash";
			case Backslash: "Backslash";
			case Percent: "Percent";
			case Less: "Less";
			case Greater: "Greater";
			case LessEqual: "LessEqual";
			case GreaterEqual: "GreaterEqual";
			case EqualEqual: "EqualEqual";
			case NotEqual: "NotEqual";
			case Not: "Not";
			case BitNot: "BitNot";
			case AndAnd: "AndAnd";
			case OrOr: "OrOr";
			case Ampersand: "Ampersand";
			case Pipe: "Pipe";
			case Caret: "Caret";
			case LeftBracket: "LeftBracket";
			case RightBracket: "RightBracket";
			case Question: "Question";
			case NullCoalesce: "NullCoalesce";
			case At: "At";
			case Dollar: "Dollar";
			case Eof: "Eof";
		};
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
