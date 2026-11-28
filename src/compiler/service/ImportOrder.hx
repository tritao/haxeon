package compiler.service;

import compiler.core.Source.SourceFile;
import compiler.service.UnusedImports.ImportTarget;
import compiler.syntax.ConditionalCompilation;
import compiler.syntax.Lexer;
import compiler.syntax.Token;
import compiler.syntax.Token.TokenKind;

/** A run of import lines that is not in order, with the same lines sorted, or why it is left as written. */
typedef ImportBlock = {
	/** Source offsets of the whole lines the run occupies, from the start of its first line to the end of its last (no newline). */
	final start:Int;

	final end:Int;

	/** The lines in order, or null when sorting could change what a name means (see `unsafe`). */
	final sorted:Null<String>;

	final unsafe:Null<String>;
}

/**
 * Keeps import statements in order: within each run of consecutive import lines, sorted by path (ASCII, so `compiler.core.Diagnostic` comes
 * before `compiler.ffi.HxiAbi`). A run ends at anything that is not an import line: a blank line, a comment, a conditional-compilation
 * line, a `using`, or an import that shares its line with other code. Those boundaries stay where they are, so grouping and `#if`
 * blocks are preserved.
 *
 * A later import of a name wins over an earlier one, so a run is only sorted when no two of its imports make the same short name
 * visible: the alias, or the type an import names, or for a whole module every name it declares (resolved like `UnusedImports`).
 * A run with a package wildcard (`pack.*`) is never sorted, since what it brings is not known here.
 */
class ImportOrder {
	/**
	 * Tokens of `source` with its conditional directives blanked out (offsets preserved), so a file with `#if` can be read. The
	 * directive lines are still text in `source`, so they still end a run.
	 */
	public static function tokens(path:String, source:String):Array<Token> {
		var file = new SourceFile(path, source);
		return new Lexer(new SourceFile(path, ConditionalCompilation.process(file, [], false).text)).tokenize();
	}

	/** The runs of `source` that are out of order; `tokens` come from `tokens(path, source)`. */
	public static function find(source:String, tokens:Array<Token>,
			resolve:String->Null<ImportTarget>):Array<ImportBlock> {
		var blocks:Array<ImportBlock> = [];
		for (run in runs(source, tokens)) {
			var keys = run.map(line -> line.key);
			var ordered = keys.copy();
			ordered.sort(compare);
			if (ordered.join("\n") == keys.join("\n"))
				continue;
			var start = run[0].start,
				end = run[run.length - 1].end,
				unsafe = conflict(run, resolve);
			var sorted:Null<String> = null;
			if (unsafe == null) {
				var lines = run.copy();
				lines.sort((a, b) -> compare(a.key, b.key));
				sorted = lines.map(line -> source.substring(line.start, line.end)).join("\n");
			}
			blocks.push({
				start: start,
				end: end,
				sorted: sorted,
				unsafe: unsafe
			});
		}
		return blocks;
	}

	/** `source` with every run that can be sorted safely sorted. */
	public static function sort(source:String, tokens:Array<Token>, resolve:String->Null<ImportTarget>):String {
		var blocks = find(source, tokens, resolve).filter(block -> block.sorted != null);
		blocks.sort((a, b) -> b.start - a.start);
		var result = source;
		for (block in blocks)
			result = result.substr(0, block.start) + block.sorted + result.substr(block.end);
		return result;
	}

	static function compare(a:String, b:String):Int
		return a < b ? -1 : a > b ? 1 : 0;

	/** Consecutive whole-line import statements, as runs of at least two. */
	static function runs(source:String, tokens:Array<Token>):Array<Array<ImportLine>> {
		var result:Array<Array<ImportLine>> = [], current:Array<ImportLine> = [], index = 0;
		function close() {
			if (current.length > 1)
				result.push(current);
			current = [];
		}
		while (index < tokens.length) {
			if (tokens[index].kind != TokenKind.Import) {
				index++;
				continue;
			}
			var first = index, parts:Array<String> = [], alias:Null<String> = null, wildcard = false;
			index++;
			while (index < tokens.length && tokens[index].kind != TokenKind.Semicolon
				&& tokens[index].kind != TokenKind.Eof) {
				var token = tokens[index];
				if (token.kind == TokenKind.Star)
					wildcard = true;
				else if (token.kind == TokenKind.Identifier && token.text == "as" && parts.length > 0)
					alias = index + 1 < tokens.length ? tokens[index + 1].text : null;
				else if (token.kind == TokenKind.Identifier && alias == null)
					parts.push(token.text);
				index++;
			}
			if (index >= tokens.length || tokens[index].kind != TokenKind.Semicolon) {
				close();
				continue;
			}
			var statementStart = tokens[first].span.start,
				statementEnd = tokens[index].span.end;
			var lineStart = source.lastIndexOf("\n", statementStart - 1) + 1,
				lineEnd = source.indexOf("\n", statementEnd);
			if (lineEnd < 0)
				lineEnd = source.length;
			var alone = StringTools.trim(source.substring(lineStart, statementStart)) == ""
				&& StringTools.trim(source.substring(statementEnd, lineEnd)) == "";
			if (!alone) {
				close();
				continue;
			}
			// Only a newline may separate two lines of one run: a blank line, comment or directive between them ends it.
			if (current.length > 0 && lineStart != current[current.length - 1].end + 1)
				close();
			var path = parts.join(".") + (wildcard ? ".*" : "");
			current.push({
				start: lineStart,
				end: lineEnd,
				key: path + (alias != null ? ' as $alias' : ""),
				path: parts.join("."),
				alias: alias,
				wildcard: wildcard
			});
		}
		close();
		return result;
	}

	/** Why sorting the run could change what a name means, or null when it cannot. */
	static function conflict(run:Array<ImportLine>, resolve:String->Null<ImportTarget>):Null<String> {
		var owners = new Map<String, String>();
		for (line in run) {
			if (line.wildcard && resolve(line.path) == null)
				return '${line.path}.* imports names that are not known here';
			for (name in bound(line, resolve)) {
				var other = owners.get(name);
				if (other != null && other != line.key)
					return '$name is imported by both $other and ${line.key}';
				owners.set(name, line.key);
			}
		}
		return null;
	}

	/** The short names an import line makes visible. */
	static function bound(line:ImportLine, resolve:String->Null<ImportTarget>):Array<String> {
		if (line.alias != null)
			return [line.alias];
		var parts = line.path.split("."), last = parts[parts.length - 1];
		var target = resolve(line.path);
		if (target == null)
			return line.wildcard ? [] : [last];
		var names = UnusedImports.visibleNames(target.program, line.wildcard ? null : target.member);
		if (names == null)
			return line.wildcard ? [] : [last];
		if (!line.wildcard && names.indexOf(last) < 0)
			names.push(last);
		return names;
	}
}

private typedef ImportLine = {
	final start:Int;
	final end:Int;

	/** What the run is sorted by: the path, `.*` for a wildcard, and ` as Alias`. */
	final key:String;

	final path:String;
	final alias:Null<String>;
	final wildcard:Bool;
}
