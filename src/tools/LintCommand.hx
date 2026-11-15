package tools;

import compiler.Source.SourceFile;
import compiler.formatter.ProjectFormat;
import compiler.formatter.Formatter;
import compiler.service.ImportOrder;
import compiler.service.UnusedImports;
import compiler.service.UnusedImports.ImportTarget;
import compiler.service.UnusedImports.UnusedImport;
import compiler.syntax.Ast.AstProgram;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * `haxeon lint [--fix] [--only RULE] [--manifest FILE]... FILE...` reports unused imports (rule `unused-imports`) and runs of
 * imports out of order (rule `import-order`, see ImportOrder); `--only` checks one rule.
 *
 * Imports resolve against the source roots of the given manifests and of the directory each file's package declaration implies. An
 * import that resolves nowhere is assumed used, so a missing manifest makes the check quieter, never wrong. `--fix` deletes the
 * statements, sorts the runs that can be sorted without changing what a name means, and reformats a file that was formatted before.
 * A run whose order matters (two imports of one name) is left as written and not reported.
 */
class LintCommand {
	final roots:Array<String> = [];
	final programs:Map<String, Null<AstProgram>> = [];

	function new() {}

	public static function run(arguments:Array<String>):Int {
		var fix = false, manifests:Array<String> = [], paths:Array<String> = [], index = 0, checkUnused = true, checkOrder = true;
		while (index < arguments.length) {
			var argument = arguments[index++];
			if (argument == "--fix")
				fix = true;
			else if (argument == "--only") {
				if (index >= arguments.length)
					throw 'Option "--only" requires a rule: unused-imports or import-order';
				switch arguments[index++] {
					case "unused-imports": checkOrder = false;
					case "import-order": checkUnused = false;
					case other: throw 'Unknown lint rule "$other" (known: unused-imports, import-order)';
				}
			}
			else if (argument == "--manifest") {
				if (index >= arguments.length)
					throw 'Option "--manifest" requires a value';
				manifests.push(arguments[index++]);
			} else if (StringTools.startsWith(argument, "-"))
				throw 'Unknown lint option "$argument"';
			else
				paths.push(argument);
		}
		if (paths.length == 0)
			throw "haxeon lint requires at least one file";
		var command = new LintCommand();
		for (manifest in manifests)
			command.addManifest(manifest);
		var projects = new ProjectFormat(), found = 0;
		for (path in SourceFiles.expand(paths)) {
			var source = File.getContent(path), file = new SourceFile(path, source);
			// Unused imports read the raw tokens: with directives blanked out, an import used only in an inactive branch would look
			// unused, so a file the raw lexer rejects (it has `#if`) is not judged. Order reads through the directives.
			var tokens:Null<Array<compiler.syntax.Token>> = try new Lexer(file).tokenize() catch (_:Dynamic) null;
			var orderTokens:Null<Array<compiler.syntax.Token>> = checkOrder ? (try ImportOrder.tokens(path, source) catch (_:Dynamic) null) : null;
			var rootTokens = tokens ?? orderTokens;
			if (rootTokens == null)
				continue;
			var root = packageRoot(path, rootTokens);
			if (root != null)
				command.addRoot(root);
			var unused = checkUnused && tokens != null ? UnusedImports.find(tokens, command.resolve) : [];
			var unordered = orderTokens != null ? ImportOrder.find(source, orderTokens, command.resolve).filter(block -> block.sorted != null) : [];
			if (unused.length == 0 && unordered.length == 0)
				continue;
			found += unused.length + unordered.length;
			for (item in unused)
				Sys.println('$path:${lineOf(source, item.start)}: unused import ${item.path}');
			for (block in unordered)
				Sys.println('$path:${lineOf(source, block.start)}: imports not in order');
			if (fix) {
				var config = projects.forFile(path), wasFormatted = Formatter.format(source, config) == source, edited = remove(source, unused);
				// Sorted after the removal, which can join two runs or empty one.
				if (orderTokens != null)
					edited = ImportOrder.sort(edited, ImportOrder.tokens(path, edited), command.resolve);
				if (wasFormatted) {
					var formatted = Formatter.format(edited, config);
					if (formatted != null)
						edited = formatted;
				}
				File.saveContent(path, edited);
			}
		}
		return found > 0 && !fix ? 1 : 0;
	}

	function addManifest(path:String):Void {
		var raw:Dynamic = Json.parse(File.getContent(SourceFiles.requireFile(path))), directory = Path.directory(path);
		var sourceRoots:Array<String> = raw.sourceRoots == null ? ["src"] : raw.sourceRoots;
		for (sourceRoot in sourceRoots)
			addRoot(Path.join([directory == "" ? "." : directory, sourceRoot]));
	}

	function addRoot(root:String):Void {
		if (roots.indexOf(root) < 0)
			roots.push(root);
	}

	/** The directory a source file's package declaration implies as its root. */
	static function packageRoot(path:String, tokens:Array<compiler.syntax.Token>):Null<String> {
		var parts:Array<String> = [], index = 0;
		if (tokens.length == 0 || tokens[0].kind != compiler.syntax.Token.TokenKind.Package)
			return Path.directory(path);
		index = 1;
		while (index < tokens.length && tokens[index].kind != compiler.syntax.Token.TokenKind.Semicolon) {
			if (tokens[index].kind == compiler.syntax.Token.TokenKind.Identifier)
				parts.push(tokens[index].text);
			index++;
		}
		var directory = Path.directory(path), expected = parts.join("/");
		if (expected == "")
			return directory;
		return StringTools.endsWith(directory, "/" + expected) || directory == expected ? directory.substr(0, directory.length - expected.length) : null;
	}

	/** The module an import names: the longest prefix of the path that is a source file, and the type after it. */
	function resolve(importPath:String):Null<ImportTarget> {
		var parts = importPath.split("."), count = parts.length;
		while (count > 0) {
			var module = parts.slice(0, count).join("/") + ".hx";
			for (root in roots) {
				var program = load(Path.join([root == "" ? "." : root, module]));
				if (program != null) {
					var member = count < parts.length ? parts[count] : null;
					return count < parts.length - 1 ? null : {program: program, member: member};
				}
			}
			count--;
		}
		return null;
	}

	function load(path:String):Null<AstProgram> {
		if (programs.exists(path))
			return programs.get(path);
		var program:Null<AstProgram> = null;
		if (FileSystem.exists(path) && !FileSystem.isDirectory(path))
			try
				program = new Parser(new Lexer(new SourceFile(path, File.getContent(path))).tokenize()).parseProgram()
			catch (_:Dynamic) {}
		programs.set(path, program);
		return program;
	}

	static function lineOf(source:String, offset:Int):Int {
		var line = 1;
		for (index in 0...offset)
			if (source.charCodeAt(index) == "\n".code)
				line++;
		return line;
	}

	/** Deletes whole statements, and the line when nothing else stays on it. */
	static function remove(source:String, unused:Array<UnusedImport>):String {
		var result = source, ordered = unused.copy();
		ordered.sort((left, right) -> right.start - left.start);
		for (item in ordered) {
			var start = item.start, end = item.end;
			var lineStart = result.lastIndexOf("\n", start - 1) + 1, lineEnd = result.indexOf("\n", end);
			if (lineEnd < 0)
				lineEnd = result.length;
			if (StringTools.trim(result.substring(lineStart, start)) == "" && StringTools.trim(result.substring(end, lineEnd)) == "") {
				start = lineStart;
				end = Std.int(Math.min(lineEnd + 1, result.length));
			}
			result = result.substr(0, start) + result.substr(end);
		}
		return result;
	}
}
