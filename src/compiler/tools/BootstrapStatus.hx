package compiler.tools;

import compiler.Lexer;
import compiler.Parser;
import compiler.Token.TokenKind;
import compiler.Source.SourceFile;
import compiler.modules.Compiler;
import compiler.RuntimeAbi as CompilerRuntimeAbi;
import compiler.Diagnostic.CompileError;
import haxe.Json;
import sys.FileSystem;
import sys.io.File;

/** Frontend readiness and failure details measured for one source file. */
typedef FileStatus = {
	final path:String;
	final bytes:Int;
	final lexed:Bool;
	final parsed:Bool;
	final functions:Int;
	final featurePressure:Map<String, Int>;
	final failedStage:Null<String>;
	final line:Null<Int>;
	final column:Null<Int>;
	final error:Null<String>;
}

/** Outcome of attempting a complete bootstrap project compilation. */
typedef ProjectStatus = {
	final entryModule:String;
	final attempted:Bool;
	final compiled:Bool;
	final error:Null<String>;
}

/** Aggregate machine-readable bootstrap readiness report. */
typedef BootstrapReport = {
	final roots:Array<String>;
	final files:Int;
	final lexed:Int;
	final parsed:Int;
	final functions:Int;
	final project:ProjectStatus;
	final featurePressure:Array<{name:String, occurrences:Int}>;
	final failures:Array<{
		path:String,
		failedStage:String,
		line:Null<Int>,
		column:Null<Int>,
		error:String
	}>;
}

/** Measures bootstrap readiness by executing the real frontend on source files. */
class BootstrapStatus {
	public static function main():Void
		run(Sys.args());

	public static function run(arguments:Array<String>):Void {
		var json = false;
		var entryModule = "Main";
		var roots:Array<String> = [];
		for (argument in arguments) {
			if (argument == "--json")
				json = true;
			else if (StringTools.startsWith(argument, "--entry="))
				entryModule = argument.substring("--entry=".length, argument.length);
			else
				roots.push(argument);
		}
		if (roots.length == 0)
			roots = ["src", "stdlib"];

		var paths:Array<String> = [];
		for (root in roots)
			collect(root, paths);
		paths.sort(Reflect.compare);
		var files = [for (path in paths) inspect(path)];
		var report = summarize(roots, files, inspectProject(roots, paths, files, entryModule));
		if (json)
			Sys.println(Json.stringify(report, null, "\t"));
		else
			printSummary(report, files);
	}

	static function collect(path:String, output:Array<String>):Void {
		if (!FileSystem.exists(path))
			throw 'Bootstrap status path does not exist: $path';
		if (!FileSystem.isDirectory(path)) {
			if (StringTools.endsWith(path, ".hx"))
				output.push(path);
			return;
		}
		var children = FileSystem.readDirectory(path);
		children.sort(Reflect.compare);
		for (child in children)
			collect(path + "/" + child, output);
	}

	static function inspect(path:String):FileStatus {
		var source = File.getContent(path),
			file = new SourceFile(path, source);
		var pressure = featurePressure(source), lexed = false, parsed = false, functions = 0, failedStage:Null<String> = null, line:Null<Int> = null,
			column:Null<Int> = null, error:Null<String> = null;
		try {
			var tokens = new Lexer(file).tokenize();
			lexed = true;
			try {
				var program = new Parser(tokens).parseProgram();
				parsed = true;
				functions = program.functions.length;
			} catch (failure:CompileError) {
				failedStage = "parse";
				error = failure.diagnostic.message;
				var location = sourceLocation(source, failure.diagnostic.span.start);
				line = location.line;
				column = location.column;
			} catch (failure:Dynamic) {
				failedStage = "parse";
				error = Std.string(failure);
			}
		} catch (failure:CompileError) {
			failedStage = "lex";
			error = failure.diagnostic.message;
			var location = sourceLocation(source, failure.diagnostic.span.start);
			line = location.line;
			column = location.column;
		} catch (failure:Dynamic) {
			failedStage = "lex";
			error = Std.string(failure);
		}
		return {
			path: path,
			bytes: source.length,
			lexed: lexed,
			parsed: parsed,
			functions: functions,
			featurePressure: pressure,
			failedStage: failedStage,
			line: line,
			column: column,
			error: error
		};
	}

	static function sourceLocation(source:String, offset:Int):{line:Int, column:Int} {
		var line = 1, column = 1;
		for (position in 0...offset)
			if (source.charCodeAt(position) == 10) {
				line++;
				column = 1;
			} else
				column++;
		return {line: line, column: column};
	}

	static function inspectProject(roots:Array<String>, paths:Array<String>, files:Array<FileStatus>, entryModule:String):ProjectStatus {
		var parseFailures = files.length - countFiles(files, function(file) return file.parsed);
		if (parseFailures > 0)
			return {
				entryModule: entryModule,
				attempted: false,
				compiled: false,
				error: 'Blocked by $parseFailures file(s) that do not parse'
			};

		var compiler = new Compiler();
		CompilerRuntimeAbi.register(compiler);
		BootstrapSources.load(compiler, roots, paths);
		try {
			compiler.compile(entryModule);
			return {
				entryModule: entryModule,
				attempted: true,
				compiled: true,
				error: null
			};
		} catch (failure:CompileError) {
			var source = failure.diagnostic.span.file,
				location = sourceLocation(source.text, failure.diagnostic.span.start);
			return {
				entryModule: entryModule,
				attempted: true,
				compiled: false,
				error: '${source.path}:${location.line}:${location.column}: ${failure.diagnostic.message}'
			};
		} catch (failure:Dynamic) {
			return {
				entryModule: entryModule,
				attempted: true,
				compiled: false,
				error: Std.string(failure)
			};
		}
	}

	static function summarize(roots:Array<String>, files:Array<FileStatus>, project:ProjectStatus):BootstrapReport {
		var pressure:Map<String, Int> = [];
		for (file in files)
			for (name => count in file.featurePressure)
				pressure.set(name, (pressure.get(name) == null ? 0 : pressure.get(name)) + count);
		var ordered = [for (name in pressure.keys()) name];
		ordered.sort(Reflect.compare);
		var sortedPressure = [for (name in ordered) {name: name, occurrences: pressure.get(name)}];
		return {
			roots: roots,
			files: files.length,
			lexed: countFiles(files, function(file) return file.lexed),
			parsed: countFiles(files, function(file) return file.parsed),
			functions: sumFunctions(files),
			project: project,
			featurePressure: sortedPressure,
			failures: [
				for (file in files)
					if (file.error != null) {
						path: file.path,
						failedStage: file.failedStage,
						line: file.line,
						column: file.column,
						error: file.error
					}
			]
		};
	}

	static function printSummary(report:BootstrapReport, files:Array<FileStatus>):Void {
		Sys.println("Bootstrap readiness");
		Sys.println('  files:    ${report.files}');
		Sys.println('  lexed:    ${report.lexed}/${report.files}');
		Sys.println('  parsed:   ${report.parsed}/${report.files}');
		Sys.println('  functions:${report.functions}');
		var projectState = report.project.compiled ? "compiled" : report.project.attempted ? "failed" : "blocked";
		Sys.println('  project:  $projectState (entry ${report.project.entryModule})');
		if (report.project.error != null)
			Sys.println('            ${report.project.error}');
		Sys.println("Feature pressure:");
		for (feature in report.featurePressure)
			Sys.println('  ${feature.name}: ${feature.occurrences}');
		if (report.failures.length > 0) {
			Sys.println("Failures:");
			for (failure in report.failures) {
				var location = failure.line == null ? "" : ':${failure.line}:${failure.column}';
				Sys.println('  ${failure.path}$location [${failure.failedStage}]: ${failure.error}');
			}
		}
	}

	static function countFiles(files:Array<FileStatus>, predicate:FileStatus->Bool):Int {
		var count = 0;
		for (file in files)
			if (predicate(file))
				count++;
		return count;
	}

	static function sumFunctions(files:Array<FileStatus>):Int {
		var count = 0;
		for (file in files)
			count += file.functions;
		return count;
	}

	static function featurePressure(source:String):Map<String, Int> {
		var result:Map<String, Int> = [];
		for (feature in [
			"package",
			"import",
			"class",
			"interface",
			"enum",
			"typedef",
			"abstract",
			"new",
			"switch",
			"try",
			"catch",
			"throw",
			"macro",
			"@:metadata"
		])
			result.set(feature, countWord(source, feature));
		return result;
	}

	static function countWord(source:String, word:String):Int {
		var count = 0, offset = 0;
		while (true) {
			var found = source.indexOf(word, offset);
			if (found < 0)
				return count;
			var before = found == 0 ? 0 : source.charCodeAt(found - 1);
			var afterPosition = found + word.length;
			var after = afterPosition >= source.length ? 0 : source.charCodeAt(afterPosition);
			if ((word.charAt(0) == "@" || !isIdentifierPart(before)) && (word.charAt(0) == "@" || !isIdentifierPart(after)))
				count++;
			offset = afterPosition;
		}
	}

	static function isIdentifierPart(code:Int):Bool
		return code >= 48 && code <= 57 || code >= 65 && code <= 90 || code >= 97 && code <= 122 || code == 95;
}
