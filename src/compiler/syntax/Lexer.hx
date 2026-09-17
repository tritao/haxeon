package compiler.syntax;

import compiler.Source.SourceFile;
import compiler.syntax.SyntaxScanner.SyntaxTokenKind;
import compiler.syntax.Token.TokenKind;

/**
	Compatibility adapter from the shared lossless scanner to compiler tokens.

	Trivia is intentionally filtered here so the parser and semantic pipeline
	retain their existing token contract while formatter/CST work migrates.
 */
class Lexer {
	final file:SourceFile;
	final source:String;
	final checkpointCallback:Null<Void->Void>;

	public function new(file:SourceFile, ?source:String, ?checkpoint:Void->Void) {
		this.file = file;
		this.source = source == null ? file.text : source;
		this.checkpointCallback = checkpoint;
	}

	public function tokenize():Array<Token> {
		var scanner = new SyntaxScanner(file, source, checkpointCallback, true, false),
			result:Array<Token> = [];
		for (token in scanner.scan())
			switch token.kind {
				case SyntaxTokenKind.Syntax(kind):
					result.push(new Token(kind, token.text, token.span));
				case SyntaxTokenKind.Whitespace, SyntaxTokenKind.Newline,
					SyntaxTokenKind.LineComment, SyntaxTokenKind.BlockComment, SyntaxTokenKind.DocComment:
					// Compiler trivia remains outside the parser token stream.
				case SyntaxTokenKind.Directive, SyntaxTokenKind.Unknown:
					// Strict scanning rejects both before they can reach this adapter.
			}
		result.push(new Token(TokenKind.Eof, "", file.span(scanner.sourceLength, scanner.sourceLength)));
		return result;
	}
}
