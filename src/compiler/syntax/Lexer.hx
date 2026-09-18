package compiler.syntax;

import compiler.Source.SourceFile;
import compiler.syntax.SyntaxScanner.LosslessToken;
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
			result = tokenizeLossless(file, scanner.scan(), scanner.sourceLength);
		return result;
	}

	/** Adapts an already scanned strict lossless stream without rescanning it. */
	public static function tokenizeLossless(file:SourceFile, losslessTokens:Array<LosslessToken>, ?sourceLength:Int):Array<Token> {
		var result:Array<Token> = [];
		result.resize(losslessTokens.length + 1);
		var resultLength = 0;
		for (token in losslessTokens)
			switch token.kind {
				case SyntaxTokenKind.Syntax(kind):
					result[resultLength++] = token.sourceBacked ? Token.fromSource(kind, token.span) : new Token(kind, token.text, token.span);
				case SyntaxTokenKind.Whitespace, SyntaxTokenKind.Newline,
					SyntaxTokenKind.LineComment, SyntaxTokenKind.BlockComment, SyntaxTokenKind.DocComment:
					// Compiler trivia remains outside the parser token stream.
				case SyntaxTokenKind.Directive, SyntaxTokenKind.Unknown:
					throw 'Lossless compiler-token adaptation received non-syntax input at ${token.span.start}';
			}
		var end = sourceLength == null ? file.bytes.length : sourceLength;
		result[resultLength++] = new Token(TokenKind.Eof, "", file.span(end, end));
		result.resize(resultLength);
		return result;
	}
}
