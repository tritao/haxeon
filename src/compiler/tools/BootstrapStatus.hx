package compiler.tools;

import compiler.Lexer;
import compiler.Parser;
import compiler.Token.TokenKind;
import compiler.Source.SourceFile;
import compiler.types.Typer;
import haxe.Json;
import sys.FileSystem;
import sys.io.File;

typedef FileStatus = {
	final path:String;
	final bytes:Int;
	final lexed:Bool;
	final parsed:Bool;
	final typed:Bool;
	final functions:Int;
	final featurePressure:Map<String, Int>;
	final error:Null<String>;
}

typedef BootstrapReport = {
	final roots:Array<String>;
	final files:Int;
	final lexed:Int;
	final parsed:Int;
	final typed:Int;
	final functions:Int;
	final featurePressure:Array<{name:String, occurrences:Int}>;
	final failures:Array<{path:String, error:Null<String>}>;
}

/** Measures bootstrap readiness by executing the real frontend on source files. */
class BootstrapStatus {
	public static function run(arguments:Array<String>):Void {
		var json = false;
		var roots = [];
		for (argument in arguments) {
			if (argument == "--json")
				json = true;
			else
				roots.push(argument);
		}
		if (roots.length == 0)
			roots = ["src"];

		var paths = [];
		for (root in roots)
			collect(root, paths);
		paths.sort(Reflect.compare);
		var files = [for (path in paths) inspect(path)];
		var report = summarize(roots, files);
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
		var pressure = featurePressure(source), lexed = false, parsed = false, typed = false, functions = 0, error:Null<String> = null;
		try {
			var tokens = new Lexer(file).tokenize();
			lexed = true;
			try {
				var program = new Parser(tokens).parseProgram();
				parsed = true;
				functions = program.functions.length;
				try {
					Typer.type(program);
					typed = true;
				} catch (failure:Dynamic)
					error = Std.string(failure);
			} catch (failure:Dynamic)
				error = Std.string(failure);
		} catch (failure:Dynamic)
			error = Std.string(failure);
		return {
			path: path,
			bytes: source.length,
			lexed: lexed,
			parsed: parsed,
			typed: typed,
			functions: functions,
			featurePressure: pressure,
			error: error
		};
	}

	static function summarize(roots:Array<String>, files:Array<FileStatus>):BootstrapReport {
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
			typed: countFiles(files, function(file) return file.typed),
			functions: sumFunctions(files),
			featurePressure: sortedPressure,
			failures: [
				for (file in files)
					if (file.error != null) {
						path: file.path,
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
		Sys.println('  typed:    ${report.typed}/${report.files}');
		Sys.println('  functions:${report.functions}');
		Sys.println("Feature pressure:");
		for (feature in report.featurePressure)
			Sys.println('  ${feature.name}: ${feature.occurrences}');
		if (report.failures.length > 0) {
			Sys.println("Failures:");
			for (failure in report.failures)
				Sys.println('  ${failure.path}: ${failure.error}');
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
