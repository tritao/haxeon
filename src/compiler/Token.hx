package compiler;

enum TokenKind {
    Function;
    Var;
    Return;
    TypeInt;
    Identifier;
    Integer;
    LeftParen;
    RightParen;
    LeftBrace;
    RightBrace;
    Colon;
    Semicolon;
    Comma;
    Assign;
    Plus;
    Minus;
    Eof;
}

class Token {
    public final kind:TokenKind;
    public final text:String;
    public final offset:Int;

    public function new(kind:TokenKind, text:String, offset:Int) {
        this.kind = kind;
        this.text = text;
        this.offset = offset;
    }
}
