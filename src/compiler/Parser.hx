package compiler;

import compiler.Ast.AstExpression;
import compiler.Ast.AstFunction;
import compiler.Ast.AstProgram;
import compiler.Ast.AstStatement;
import compiler.Ast.AstType;
import compiler.Token.TokenKind;
import compiler.Diagnostic.CompileError;

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
        var start = consume(TokenKind.Function).span;
        var name = consume(TokenKind.Identifier).text;
        consume(TokenKind.LeftParen);
        var arguments = [];
        if (!check(TokenKind.RightParen)) {
            do {
                var argumentName = consume(TokenKind.Identifier).text;
                consume(TokenKind.Colon);
                arguments.push({name: argumentName, type: parseType(), span: previous().span});
            } while (match(TokenKind.Comma));
        }
        consume(TokenKind.RightParen);
        consume(TokenKind.Colon);
        var result = parseType();
        consume(TokenKind.LeftBrace);
        var statements = [];
        while (!check(TokenKind.RightBrace))
            statements.push(parseStatement());
        var end = consume(TokenKind.RightBrace).span;
        return {name: name, arguments: arguments, result: result, statements: statements, span: start.merge(end)};
    }

    function parseStatement():AstStatement {
        if (match(TokenKind.Var)) {
            var start = previous().span;
            var name = consume(TokenKind.Identifier).text;
            var type = match(TokenKind.Colon) ? parseType() : null;
            consume(TokenKind.Assign);
            var initializer = parseExpression();
            var end = consume(TokenKind.Semicolon).span;
            return VarDeclaration(name, type, initializer, start.merge(end));
        }
        if (match(TokenKind.Return)) {
            var start = previous().span;
            var expression = parseExpression();
            var end = consume(TokenKind.Semicolon).span;
            return Return(expression, start.merge(end));
        }
        if (match(TokenKind.If)) {
            var start = previous().span;
            consume(TokenKind.LeftParen);
            var condition = parseExpression();
            consume(TokenKind.RightParen);
            var thenBranch = parseStatementOrBlock();
            var elseBranch = match(TokenKind.Else) ? parseStatementOrBlock() : [];
            var end = elseBranch.length > 0 ? statementSpan(elseBranch[elseBranch.length - 1]) : statementSpan(thenBranch[thenBranch.length - 1]);
            return If(condition, thenBranch, elseBranch, start.merge(end));
        }
        fail(current(), "Expected statement");
        return null;
    }

    function parseExpression():AstExpression {
        var expression = parseAdditive();
        if (check(TokenKind.Less) || check(TokenKind.LessEqual) || check(TokenKind.EqualEqual)) {
            var operation = advance().kind;
            var right = parseAdditive();
            var span = expressionSpan(expression).merge(expressionSpan(right));
            expression = switch operation {
                case TokenKind.Less: Less(expression, right, span);
                case TokenKind.LessEqual: LessEqual(expression, right, span);
                default: Equal(expression, right, span);
            }
        }
        return expression;
    }

    function parseAdditive():AstExpression {
        var expression = parsePrimary();
        while (check(TokenKind.Plus) || check(TokenKind.Minus)) {
            var operation = advance().kind;
            var right = parsePrimary();
            var span = expressionSpan(expression).merge(expressionSpan(right));
            expression = operation == TokenKind.Plus ? Add(expression, right, span) : Sub(expression, right, span);
        }
        return expression;
    }

    function parsePrimary():AstExpression {
        if (match(TokenKind.Integer))
            return IntegerLiteral(Std.parseInt(previous().text), previous().span);
        if (match(TokenKind.Identifier)) {
            var name = previous().text;
            var start = previous().span;
            while (match(TokenKind.Dot)) {
                name += "." + consume(TokenKind.Identifier).text;
            }
            if (!match(TokenKind.LeftParen))
                return Variable(name, start);
            var arguments = [];
            if (!check(TokenKind.RightParen)) {
                do arguments.push(parseExpression()) while (match(TokenKind.Comma));
            }
            var end = consume(TokenKind.RightParen).span;
            return Call(name, arguments, start.merge(end));
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
        if (match(TokenKind.TypeInt)) return IntType;
        consume(TokenKind.TypeBool);
        return BoolType;
    }

    function parseStatementOrBlock():Array<AstStatement> {
        if (!match(TokenKind.LeftBrace)) return [parseStatement()];
        var statements = [];
        while (!check(TokenKind.RightBrace)) statements.push(parseStatement());
        consume(TokenKind.RightBrace);
        return statements;
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
        throw new CompileError(new Diagnostic("E0002", message, token.span));

    static function expressionSpan(expression:AstExpression) return switch expression {
        case IntegerLiteral(_, span), Variable(_, span), Add(_, _, span), Sub(_, _, span), Less(_, _, span), LessEqual(_, _, span), Equal(_, _, span), Call(_, _, span): span;
    }

    static function statementSpan(statement:AstStatement) return switch statement {
        case VarDeclaration(_, _, _, span), Return(_, span), If(_, _, _, span): span;
    }
}
