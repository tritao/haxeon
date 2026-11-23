package tools;

import compiler.core.InternalError;
import compiler.core.Source.SourceFile;
import compiler.formatter.ProjectFormat;
import compiler.formatter.Formatter;
import compiler.service.ImportOrder;
import compiler.service.UnusedImports;
import compiler.service.UnusedImports.ImportTarget;
import compiler.service.UnusedImports.UnusedImport;
import compiler.syntax.Ast.AstProgram;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import haxe.io.Path;
import project.PackageManifest;
import sys.FileSystem;
import sys.io.File;

/**
 * `haxeon lint [--fix] [--only RULE] [--manifest FILE]... FILE...` reports unused imports (rule `unused-imports`) and runs of
 * imports out of order (rule `import-order`, see ImportOrder); `--only` checks one rule. Both read syntax only. The opt-in rules
 * `unbound-local`, `module-namespace` and `throw-non-exception` (TypedLint) need the compiler's analysis, so each runs only when `--only` names it,
 * through `typedRules`, which runs it in a tool that links the compiler.
 *
 * Each file's imports resolve against its own project: the source roots of the nearest manifest (haxeon.toml or haxeon.json) and
 * of its path dependencies, the directory its package declaration implies, Haxeon's standard library, and any manifest given with `--manifest`. Never against the
 * other files of the run, so a file gets the same answer alone or with the whole tree. An import that resolves nowhere is assumed
 * used, so a missing manifest makes the check quieter, never wrong. `--fix` deletes the
 * statements, sorts the runs that can be sorted without changing what a name means, and reformats a file that was formatted before.
 * A run whose order matters (two imports of one name) is left as written and not reported.
 */
class LintCommand {
	/** Roots every file resolves against: Haxeon's standard library and the `--manifest` source roots. */
	final sharedRoots:Array<String> = [];

	/** Source roots of a project by its manifest, its path dependencies' included. */
	final projectRoots:Map<String, Array<String>> = [];

	final programs:Map<String, Null<AstProgram>> = [];

	function new() {}

	/** The rules `--only` selects; the typed ones run only when it names them. */
	static final RULES = "unused-imports, import-order, unbound-local, module-namespace, throw-non-exception";

	/**
	 * Lints the files `arguments` names. `typedRules` runs a typed rule on the expanded files and returns its status: the
	 * command line runs them in a program that links the compiler (its `lint` role, or the `LintMain` tool), a test in its own
	 * process.
	 */
	public static function run(arguments:Array<String>, ?standardLibrary:String,
			?typedRules:(rule:String, files:Array<String>) -> Int):Int {
		var fix = false,
			manifests:Array<String> = [],
			paths:Array<String> = [],
			index = 0,
			checkUnused = true,
			checkOrder = true,
			typedRule:Null<String> = null;
		while (index < arguments.length) {
			var argument = arguments[index++];
			if (argument == "--fix")
				fix = true;
			else if (argument == "--only") {
				if (index >= arguments.length)
					throw new InternalError('Option "--only" requires a rule: $RULES');
				switch arguments[index++] {
					case "unused-imports": checkOrder = false;
					case "import-order": checkUnused = false;
					case rule = "unbound-local" | "module-namespace" | "throw-non-exception":
						checkUnused = false;
						checkOrder = false;
						typedRule = rule;
					case other: throw new InternalError('Unknown lint rule "$other" (known: $RULES)');
				}
			}
				else if (argument == "--manifest") {
				if (index >= arguments.length)
					throw new InternalError('Option "--manifest" requires a value');
				manifests.push(arguments[index++]);
			} else if (StringTools.startsWith(argument, "-"))
				throw new InternalError('Unknown lint option "$argument"');
			else
				paths.push(argument);
		}
		if (paths.length == 0)
			throw new InternalError("haxeon lint requires at least one file");
		if (typedRule != null) {
			if (fix)
				throw new InternalError(switch typedRule {
					case "unbound-local": 'Rule "unbound-local" has no fix: give each local it names a type';
					case "throw-non-exception": 'Rule "throw-non-exception" has no fix: throw a haxe.Exception subclass at each throw it names';
					default: 'Rule "module-namespace" has no fix: import each member it names, or write it in full';
				});
			if (typedRules == null)
				throw new InternalError('Rule "$typedRule" needs the typed lint tool');
			return typedRules(typedRule, SourceFiles.expand(paths));
		}
		var command = new LintCommand();
		if (standardLibrary != null)
			command.sharedRoots.push(standardLibrary);
		for (manifest in manifests)
			for (root in command.manifestRoots(SourceFiles.requireFile(manifest), []))
				addTo(command.sharedRoots, root);
		var projects = new ProjectFormat(), found = 0;
		for (path in SourceFiles.expand(paths)) {
			var source = File.getContent(path), file = new SourceFile(path, source);
			// Unused imports read the raw tokens: with directives blanked out, an import used only in an inactive branch would look
			// unused, so a file the raw lexer rejects (it has `#if`) is not judged. Order reads through the directives.
			var tokens:Null<Array<compiler.syntax.Token>> = try new Lexer(file).tokenize() catch (_:Dynamic) null;
			var orderTokens:Null<Array<compiler.syntax.Token>> = checkOrder
				? (try ImportOrder.tokens(path, source) catch (_:Dynamic) null) : null;
			var rootTokens = tokens ?? orderTokens;
			if (rootTokens == null)
				continue;
			var roots = command.rootsFor(path, rootTokens),
				resolve = (importPath:String) -> command.resolve(roots, importPath);
			var unused = checkUnused
				&& tokens != null ? UnusedImports.find(compiler.syntax.TokenTable.ofTokens(tokens), resolve) : [];
			var unordered = orderTokens != null ? ImportOrder.find(source, orderTokens,
				resolve).filter(block -> block.sorted != null) : [];
			if (unused.length == 0 && unordered.length == 0)
				continue;
			found += unused.length + unordered.length;
			for (item in unused)
				Sys.println('$path:${lineOf(source, item.start)}: unused import ${item.path}');
			for (block in unordered)
				Sys.println('$path:${lineOf(source, block.start)}: imports not in order');
			if (fix) {
				var config = projects.forFile(path),
					wasFormatted = Formatter.format(source, config) == source,
					edited = remove(source, unused);
				// Sorted after the removal, which can join two runs or empty one.
				if (orderTokens != null)
					edited = ImportOrder.sort(edited, ImportOrder.tokens(path, edited), resolve);
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

	/** The roots `path` resolves against: its package root, its project's source roots, then the shared ones. */
	function rootsFor(path:String, tokens:Array<compiler.syntax.Token>):Array<String> {
		var roots:Array<String> = [], root = packageRoot(path, tokens), manifest = nearestManifest(path);
		if (root != null)
			roots.push(root);
		if (manifest != null)
			for (projectRoot in manifestRoots(manifest, []))
				addTo(roots, projectRoot);
		for (shared in sharedRoots)
			addTo(roots, shared);
		return roots;
	}

	/** The manifest (haxeon.toml or haxeon.json) in the file's directory or the nearest one above it. */
	static function nearestManifest(path:String):Null<String> {
		var directory = Path.directory(FileSystem.absolutePath(path));
		while (true) {
			var manifest = PackageManifest.find(directory);
			if (manifest != null)
				return manifest;
			var parent = Path.directory(directory);
			if (parent == directory || parent == "")
				return null;
			directory = parent;
		}
	}

	/** A manifest's source roots and, through its path dependencies, theirs. `visiting` stops a dependency cycle. */
	function manifestRoots(manifest:String, visiting:Array<String>):Array<String> {
		var key = FileSystem.absolutePath(manifest), cached = projectRoots.get(key);
		if (cached != null)
			return cached;
		if (visiting.indexOf(key) >= 0)
			return [];
		visiting.push(key);
		var roots:Array<String> = [], directory = Path.directory(key), raw:Dynamic = null;
		try
			raw = PackageManifest.decode(key, File.getContent(key))
		catch (_:Dynamic) {}
		if (raw != null) {
			var sourceRoots:Array<String> = raw.sourceRoots == null ? ["src"] : raw.sourceRoots;
			for (sourceRoot in sourceRoots)
				addTo(roots, Path.join([directory, sourceRoot]));
			var dependencies:Dynamic = raw.dependencies;
			if (dependencies != null)
				for (name in Reflect.fields(dependencies)) {
					var dependency:Dynamic = Reflect.field(dependencies, name);
					var location:Null<String> = dependency == null ? null : dependency.path;
					if (location != null) {
						var dependencyManifest = PackageManifest.find(Path.isAbsolute(location) ? location : Path.join([
							directory,
							location
						]));
						if (dependencyManifest != null)
							for (root in manifestRoots(dependencyManifest, visiting))
								addTo(roots, root);
					}
				}
		}
		projectRoots.set(key, roots);
		return roots;
	}

	static function addTo(roots:Array<String>, root:String):Void {
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
		return StringTools.endsWith(directory, "/" + expected)
			|| directory == expected ? directory.substr(0, directory.length - expected.length) : null;
	}

	/** The module an import names: the longest prefix of the path that is a source file, and the type after it. */
	function resolve(roots:Array<String>, importPath:String):Null<ImportTarget> {
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
			if (StringTools.trim(result.substring(lineStart, start)) == ""
				&& StringTools.trim(result.substring(end, lineEnd)) == "") {
				start = lineStart;
				end = Std.int(Math.min(lineEnd + 1, result.length));
			}
			result = result.substr(0, start) + result.substr(end);
		}
		return result;
	}
}
