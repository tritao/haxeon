package compiler.formatter;

import compiler.Source.SourceFile;
import compiler.syntax.SyntaxTree.SyntaxTree;

/** Compatibility facade for callers that still request formatter tokens by file. */
class FormatScanner {
	final file:SourceFile;

	public function new(file:SourceFile)
		this.file = file;

	/** Returns formatter tokens whose text concatenates byte-for-byte to input. */
	public function scan():Array<FormatToken> {
		return CstFormatterAdapter.tokens(SyntaxTree.fromSource(file));
	}

	/** The scanner's fundamental losslessness oracle. */
	public function roundTrip(tokens:Array<FormatToken>):String {
		return CstFormatterAdapter.roundTrip(tokens);
	}

	/** Returns the directive keyword without its condition or surrounding trivia. */
	public static function directiveName(text:String):String {
		return CstFormatterAdapter.directiveName(text);
	}
}
