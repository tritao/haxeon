package compiler.formatter;

import compiler.Source.SourceFile;
import compiler.Diagnostic.CompileError;
import compiler.syntax.Lexer;
import compiler.syntax.Token;

private typedef PreservedToken = {
	final kind:String;
	final text:String;
}

private class TokenizationFailure {
	public final prefix:Array<PreservedToken>;
	public final diagnostic:String;

	public function new(prefix:Array<PreservedToken>, diagnostic:String) {
		this.prefix = prefix;
		this.diagnostic = diagnostic;
	}
}

/** Every formatter shares this lexical refusal boundary, before publishing its output. */
class TokenPreservation {
	public static function verify(path:String, source:String, formatted:String):Void {
		var before:Array<PreservedToken>;
		try {
			before = tokens(path, source);
		} catch (error:TokenizationFailure) {
			throw new TokenMismatch('Cannot lex formatter input $path at token ${error.prefix.length + 1}: ${error.diagnostic}');
		}
		var after:Array<PreservedToken>;
		try {
			after = tokens(path, formatted);
		} catch (error:TokenizationFailure) {
			after = error.prefix;
			after.push({kind: "Invalid", text: error.diagnostic});
		}
		var count = Std.int(Math.max(before.length, after.length));
		for (index in 0...count) {
			var left = index < before.length ? before[index] : null;
			var right = index < after.length ? after[index] : null;
			if (left == null || right == null || left.kind != right.kind || left.text != right.text)
				throw new TokenMismatch('Formatter changed tokens in $path at token ${index + 1}: expected ${describe(left)}, got ${describe(right)}');
		}
	}

	static function describe(token:Null<PreservedToken>):String
		return token == null ? "<end>" : token.kind + " " + haxe.Json.stringify(token.text);

	static function tokens(path:String, source:String):Array<PreservedToken> {
		var result:Array<PreservedToken> = [];
		var cursor = 0;
		var file = new SourceFile(path, source);
		for (token in new FormatScanner(file).scan()) {
			switch token.kind {
				case Directive:
					append(result, path, file.slice(cursor, token.start));
					result.push({kind: "Directive", text: "#"});
					cursor = token.start + 1;
				case FormatterOff:
					append(result, path, file.slice(cursor, token.start));
					result.push({kind: "FormatterOff", text: token.text});
					cursor = token.end;
				default:
			}
		}
		append(result, path, file.slice(cursor, file.bytes.length));
		return result;
	}

	static function append(result:Array<PreservedToken>, path:String, source:String):Void {
		var file = new SourceFile(path, source);
		var scanned:Array<Token>;
		try {
			scanned = new Lexer(file).tokenize();
		} catch (error:CompileError) {
			for (token in new Lexer(new SourceFile(path, file.slice(0, error.diagnostic.span.start))).tokenize())
				if (token.kind != TokenKind.Eof)
					result.push({kind: Std.string(token.kind), text: token.text});
			throw new TokenizationFailure(result, error.diagnostic.format());
		}
		for (token in scanned)
			if (token.kind != TokenKind.Eof)
				result.push({kind: Std.string(token.kind), text: token.text});
	}
}

/** Kept distinct from an ordinary --check formatting difference. */
class TokenMismatch {
	public final message:String;

	public function new(message:String)
		this.message = message;

	public function toString():String
		return message;
}
