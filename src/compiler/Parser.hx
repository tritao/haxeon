package compiler;

import compiler.Ast.AstExpression;
import compiler.Ast.AstFunction;
import compiler.Ast.AstProgram;
import compiler.Ast.AstStatement;
import compiler.Ast.AstType;
import compiler.Token.TokenKind;

class Parser {
    final tokens:Array<Token>;
    var position:Int = 0;

    public function new(tokens:Array<Token>) {
        this.tokens = tokens;
    }

    public function parseProgram():AstProgram {
        var functions = [];
        while (!check(TokenKind.Eof))
            functions.push(parseFunction());
        return {functions: functions};
    }

    function parseFunction():AstFunction {
        consume(TokenKind.Function);
        var name = consume(TokenKind.Identifier).text;
        consume(TokenKind.LeftParen);
        var arguments = [];
        if (!check(TokenKind.RightParen)) {
            do {
                var argumentName = consume(TokenKind.Identifier).text;
                consume(TokenKind.Colon);
                arguments.push({name: argumentName, type: parseType()});
            } while (match(TokenKind.Comma));
        }
        consume(TokenKind.RightParen);
        consume(TokenKind.Colon);
        var result = parseType();
        consume(TokenKind.LeftBrace);
        var statements = [];
        while (!check(TokenKind.RightBrace))
            statements.push(parseStatement());
        consume(TokenKind.RightBrace);
        return {name: name, arguments: arguments, result: result, statements: statements};
    }

    function parseStatement():AstStatement {
        if (match(TokenKind.Var)) {
            var name = consume(TokenKind.Identifier).text;
            var type = match(TokenKind.Colon) ? parseType() : null;
            consume(TokenKind.Assign);
            var initializer = parseExpression();
            consume(TokenKind.Semicolon);
            return VarDeclaration(name, type, initializer);
        }
        if (match(TokenKind.Return)) {
            var expression = parseExpression();
            consume(TokenKind.Semicolon);
            return Return(expression);
        }
        fail(current(), "Expected statement");
        return null;
    }

    function parseExpression():AstExpression {
        var expression = parsePrimary();
        while (check(TokenKind.Plus) || check(TokenKind.Minus)) {
            var operation = advance().kind;
            var right = parsePrimary();
            expression = operation == TokenKind.Plus ? Add(expression, right) : Sub(expression, right);
        }
        return expression;
    }

    function parsePrimary():AstExpression {
        if (match(TokenKind.Integer))
            return IntegerLiteral(Std.parseInt(previous().text));
        if (match(TokenKind.Identifier)) {
            var name = previous().text;
            if (!match(TokenKind.LeftParen))
                return Variable(name);
            var arguments = [];
            if (!check(TokenKind.RightParen)) {
                do arguments.push(parseExpression()) while (match(TokenKind.Comma));
            }
            consume(TokenKind.RightParen);
            return Call(name, arguments);
        }
        if (match(TokenKind.LeftParen)) {
            var expression = parseExpression();
            consume(TokenKind.RightParen);
            return expression;
        }
        fail(current(), "Expected expression");
        return null;
    }

    function parseType():AstType {
        consume(TokenKind.TypeInt);
        return IntType;
    }

    function match(kind:TokenKind):Bool {
        if (!check(kind)) return false;
        advance();
        return true;
    }

    function consume(kind:TokenKind):Token {
        if (check(kind)) return advance();
        fail(current(), 'Expected $kind, got ${current().kind}');
        return null;
    }

    function check(kind:TokenKind):Bool
        return current().kind == kind;

    function advance():Token
        return tokens[position++];

    function current():Token
        return tokens[position];

    function previous():Token
        return tokens[position - 1];

    function fail(token:Token, message:String):Void
        throw '$message at offset ${token.offset}';
}
