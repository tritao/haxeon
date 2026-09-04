package compiler;

import compiler.Token.TokenKind;

class Lexer {
    final source:String;
    var position:Int = 0;

    public function new(source:String) {
        this.source = source;
    }

    public function tokenize():Array<Token> {
        var tokens = [];
        while (position < source.length) {
            var code = source.charCodeAt(position);
            if (isWhitespace(code)) {
                position++;
                continue;
            }
            var start = position;
            if (isIdentifierStart(code)) {
                position++;
                while (position < source.length && isIdentifierPart(source.charCodeAt(position)))
                    position++;
                var text = source.substring(start, position);
                tokens.push(new Token(keyword(text), text, start));
                continue;
            }
            if (isDigit(code)) {
                position++;
                while (position < source.length && isDigit(source.charCodeAt(position)))
                    position++;
                tokens.push(new Token(TokenKind.Integer, source.substring(start, position), start));
                continue;
            }
            position++;
            var kind = switch String.fromCharCode(code) {
                case "(": TokenKind.LeftParen;
                case ")": TokenKind.RightParen;
                case "{": TokenKind.LeftBrace;
                case "}": TokenKind.RightBrace;
                case ":": TokenKind.Colon;
                case ";": TokenKind.Semicolon;
                case ",": TokenKind.Comma;
                case "=": TokenKind.Assign;
                case "+": TokenKind.Plus;
                case "-": TokenKind.Minus;
                default: throw 'Unexpected character "${String.fromCharCode(code)}" at offset $start';
            }
            tokens.push(new Token(kind, source.substring(start, position), start));
        }
        tokens.push(new Token(TokenKind.Eof, "", position));
        return tokens;
    }

    static function keyword(text:String):TokenKind {
        return switch text {
            case "function": TokenKind.Function;
            case "var": TokenKind.Var;
            case "return": TokenKind.Return;
            case "Int": TokenKind.TypeInt;
            default: TokenKind.Identifier;
        }
    }

    static inline function isWhitespace(code:Int):Bool
        return code == 32 || code == 9 || code == 10 || code == 13;

    static inline function isDigit(code:Int):Bool
        return code >= 48 && code <= 57;

    static inline function isIdentifierStart(code:Int):Bool
        return (code >= 65 && code <= 90) || (code >= 97 && code <= 122) || code == 95;

    static inline function isIdentifierPart(code:Int):Bool
        return isIdentifierStart(code) || isDigit(code);
}
