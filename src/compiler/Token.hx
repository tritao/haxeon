package compiler;

import compiler.Source.SourceSpan;

enum TokenKind {
    Function;
    Var;
    Return;
    If;
    Else;
    TypeInt;
    TypeBool;
    Identifier;
    Integer;
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
    inline function get_offset():Int return span.start;
}
