package;

import compiler.Source.SourceFile;
import compiler.syntax.AstLowerer;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.syntax.SyntaxScanner;
import compiler.syntax.SyntaxScanner.SyntaxTokenKind;
import compiler.syntax.SyntaxTree.ParserMode;
import haxe.Json;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

private typedef Percentiles = {
	final median:Float;
	final p95:Float;
	final p99:Float;
}

private typedef Iteration = {
	final compilerLexMs:Float;
	final losslessScanMs:Float;
	final astParseMs:Float;
	final cstParseLowerMs:Float;
	final explicitLowerMs:Float;
	final compilerTokens:Int;
	final losslessSlices:Int;
	final losslessTrivia:Int;
	final cstTokens:Int;
	final cstTrivia:Int;
	final cstNodes:Int;
	final cstSyntheticTokens:Int;
}

private typedef CaseReport = {
	final modules:Int;
	final sourceBytes:Int;
	final compilerTokens:Int;
	final losslessSlices:Int;
	final losslessTrivia:Int;
	final cstTokens:Int;
	final cstTrivia:Int;
	final cstNodes:Int;
	final cstSyntheticTokens:Int;
	final compilerLexMs:Percentiles;
	final losslessScanMs:Percentiles;
	final astParseMs:Percentiles;
	final cstParseLowerMs:Percentiles;
	final explicitLowerMs:Percentiles;
	final memoryBeforeBytes:Float;
	final memoryAfterBytes:Float;
	final memoryGrowthBytes:Float;
}

/** Compares the normal AST-only compiler frontend with optional tooling CST mode. */
class SyntaxScannerBenchmarkMain {
	static function main():Void {
		var args = Sys.args(),
			iterations = intArg(args, "--iterations", 20),
			warmup = intArg(args, "--warmup", 3),
			sizes = intListArg(args, "--sizes", [8, 64, 256]),
			output = stringArg(args, "--json", "out/syntax-scanner-benchmark.json"),
			checkBudgets = hasFlag(args, "--check-budgets");
		if (iterations < 1 || warmup < 0 || sizes.length == 0)
			throw "iterations must be positive, warmup cannot be negative, and sizes cannot be empty";

		var reports:Array<CaseReport> = [];
		for (modules in sizes) {
			var file = new SourceFile('SyntaxScannerBenchmark${modules}.hx', sampleSource(modules));
			for (_ in 0...warmup)
				measure(file);
			reports.push(runCase(file, modules, iterations));
		}

		var report = {
			version: 2,
			iterations: iterations,
			warmup: warmup,
			cases: reports
		};
		ensureParent(output);
		File.saveContent(output, Json.stringify(report, null, "  ") + "\n");
		for (entry in reports)
			printCase(entry);
		if (checkBudgets)
			checkCaseBudgets(reports);
		Sys.println('JSON: $output');
	}

	static function runCase(file:SourceFile, modules:Int, iterations:Int):CaseReport {
		var before = processMemory(),
			compilerLex:Array<Float> = [],
			losslessScan:Array<Float> = [],
			astParse:Array<Float> = [],
			cstParseLower:Array<Float> = [],
			explicitLower:Array<Float> = [],
			compilerTokens = 0,
			losslessSlices = 0,
			losslessTrivia = 0,
			cstTokens = 0,
			cstTrivia = 0,
			cstNodes = 0,
			cstSyntheticTokens = 0;
		for (_ in 0...iterations) {
			var sample = measure(file);
			compilerLex.push(sample.compilerLexMs);
			losslessScan.push(sample.losslessScanMs);
			astParse.push(sample.astParseMs);
			cstParseLower.push(sample.cstParseLowerMs);
			explicitLower.push(sample.explicitLowerMs);
			compilerTokens = sample.compilerTokens;
			losslessSlices = sample.losslessSlices;
			losslessTrivia = sample.losslessTrivia;
			cstTokens = sample.cstTokens;
			cstTrivia = sample.cstTrivia;
			cstNodes = sample.cstNodes;
			cstSyntheticTokens = sample.cstSyntheticTokens;
		}
		var after = processMemory();
		return {
			modules: modules,
			sourceBytes: file.bytes.length,
			compilerTokens: compilerTokens,
			losslessSlices: losslessSlices,
			losslessTrivia: losslessTrivia,
			cstTokens: cstTokens,
			cstTrivia: cstTrivia,
			cstNodes: cstNodes,
			cstSyntheticTokens: cstSyntheticTokens,
			compilerLexMs: percentiles(compilerLex),
			losslessScanMs: percentiles(losslessScan),
			astParseMs: percentiles(astParse),
			cstParseLowerMs: percentiles(cstParseLower),
			explicitLowerMs: percentiles(explicitLower),
			memoryBeforeBytes: before,
			memoryAfterBytes: after,
			memoryGrowthBytes: before < 0 || after < 0 ? -1 : after - before
		};
	}

	static function measure(file:SourceFile):Iteration {
		var started = Sys.time(),
			compilerTokens = new Lexer(file).tokenize(),
			compilerLexMs = (Sys.time() - started) * 1000.0;
		started = Sys.time();
		var lossless = new SyntaxScanner(file).scan(),
			losslessScanMs = (Sys.time() - started) * 1000.0;
		started = Sys.time();
		new Parser(compilerTokens, null, ParserMode.AstOnly).parseProgram();
		var astParseMs = (Sys.time() - started) * 1000.0;
		started = Sys.time();
		var cstParser = new Parser(new Lexer(file).tokenize(), null, ParserMode.Cst(file)),
			cstProgram = cstParser.parseProgram(),
			cstParseLowerMs = (Sys.time() - started) * 1000.0,
			tree = cstParser.cst;
		if (tree == null)
			throw "CST parser did not publish a syntax tree";
		started = Sys.time();
		AstLowerer.lower(tree, cstProgram, false);
		var explicitLowerMs = (Sys.time() - started) * 1000.0;
		var losslessTrivia = 0;
		for (slice in lossless)
			switch slice.kind {
				case SyntaxTokenKind.Syntax(_):
				default: losslessTrivia++;
			}
		return {
			compilerLexMs: compilerLexMs,
			losslessScanMs: losslessScanMs,
			astParseMs: astParseMs,
			cstParseLowerMs: cstParseLowerMs,
			explicitLowerMs: explicitLowerMs,
			compilerTokens: compilerTokens.length,
			losslessSlices: lossless.length,
			losslessTrivia: losslessTrivia,
			cstTokens: tree.tokens.length,
			cstTrivia: tree.trivia.length,
			cstNodes: tree.grammarNodes().length,
			cstSyntheticTokens: tree.syntheticTokens.length
		};
	}

	static function sampleSource(modules:Int):String {
		var output = new StringBuf();
		for (index in 0...modules) {
			output.add('// module $index\n');
			output.add('/* retained comment for module $index */\n');
			output.add('class Type$index<T> {\n');
			output.add('\tpublic var value:T;\n');
			output.add('\tpublic function compute(input:T):T return input;\n');
			output.add('}\n');
			output.add('function use$index():Void { var item = new Type$index<Int>(); item.value; }\n');
		}
		return output.toString();
	}

	static function printCase(report:CaseReport):Void {
		Sys.println('Size ${report.modules}: ${report.sourceBytes} bytes, compiler tokens ${report.compilerTokens}, lossless slices ${report.losslessSlices}, '
			+ 'lossless trivia ${report.losslessTrivia}, CST tokens ${report.cstTokens}, CST trivia ${report.cstTrivia}, CST nodes ${report.cstNodes}');
		Sys.println('  compiler lex median/p95/p99: ${format(report.compilerLexMs.median)}/${format(report.compilerLexMs.p95)}/${format(report.compilerLexMs.p99)} ms');
		Sys.println('  lossless scan median/p95/p99: ${format(report.losslessScanMs.median)}/${format(report.losslessScanMs.p95)}/${format(report.losslessScanMs.p99)} ms');
		Sys.println('  AST-only parse median/p95/p99: ${format(report.astParseMs.median)}/${format(report.astParseMs.p95)}/${format(report.astParseMs.p99)} ms');
		Sys.println('  CST parse+lower median/p95/p99: ${format(report.cstParseLowerMs.median)}/${format(report.cstParseLowerMs.p95)}/${format(report.cstParseLowerMs.p99)} ms');
		Sys.println('  explicit lower/validate median/p95/p99: ${format(report.explicitLowerMs.median)}/${format(report.explicitLowerMs.p95)}/${format(report.explicitLowerMs.p99)} ms');
		Sys.println('  memory before/after/growth: ${formatBytes(report.memoryBeforeBytes)}/${formatBytes(report.memoryAfterBytes)}/${formatBytes(report.memoryGrowthBytes)} bytes');
	}

	static function checkCaseBudgets(reports:Array<CaseReport>):Void {
		for (report in reports) {
			var budget = report.modules <= 64 ? 100.0 : 500.0;
			if (report.compilerLexMs.p95 > budget)
				throw 'Compiler lexer budget exceeded for ${report.modules} modules: ${format(report.compilerLexMs.p95)} ms > $budget ms';
			if (report.astParseMs.p95 > budget)
				throw 'AST-only parse budget exceeded for ${report.modules} modules: ${format(report.astParseMs.p95)} ms > $budget ms';
			if (report.cstParseLowerMs.p95 > budget)
				throw 'CST parse/lower budget exceeded for ${report.modules} modules: ${format(report.cstParseLowerMs.p95)} ms > $budget ms';
		}
		Sys.println("CST benchmark budget check: passed");
	}

	static function percentiles(values:Array<Float>):Percentiles {
		var sorted = values.copy();
		sorted.sort(function(left, right) return left < right ? -1 : left > right ? 1 : 0);
		return {
			median: percentile(sorted, 0.50),
			p95: percentile(sorted, 0.95),
			p99: percentile(sorted, 0.99)
		};
	}

	static function percentile(sorted:Array<Float>, ratio:Float):Float {
		var index = Std.int(Math.min(sorted.length - 1, Math.floor(ratio * sorted.length)));
		return sorted[index];
	}

	static function processMemory():Float {
		var process:Process = null;
		try {
			process = new Process("sh", ["-c", "ps -o rss= -p $PPID"]);
			var residentKb = Std.parseInt(StringTools.trim(process.stdout.readAll().toString()));
			process.close();
			return residentKb == null || residentKb <= 0 ? -1 : residentKb * 1024.0;
		} catch (_:Dynamic) {
			if (process != null)
				process.close();
			return -1;
		}
	}

	static function intListArg(args:Array<String>, name:String, fallback:Array<Int>):Array<Int> {
		var raw = stringArg(args, name, null);
		if (raw == null)
			return fallback;
		var result:Array<Int> = [];
		for (value in raw.split(",")) {
			var parsed = Std.parseInt(StringTools.trim(value));
			if (parsed != null && parsed > 0)
				result.push(parsed);
		}
		return result;
	}

	static function intArg(args:Array<String>, name:String, fallback:Int):Int {
		var value = stringArg(args, name, null);
		return value == null ? fallback : Std.parseInt(value);
	}

	static function stringArg(args:Array<String>, name:String, fallback:Null<String>):Null<String> {
		var prefix = name + "=";
		for (index in 0...args.length) {
			if (args[index] == name && index + 1 < args.length)
				return args[index + 1];
			if (StringTools.startsWith(args[index], prefix))
				return args[index].substring(prefix.length);
		}
		return fallback;
	}

	static function hasFlag(args:Array<String>, name:String):Bool
		return args.indexOf(name) >= 0;

	static function ensureParent(path:String):Void {
		var separator = path.lastIndexOf("/");
		if (separator > 0) {
			var directory = path.substring(0, separator);
			if (!FileSystem.exists(directory))
				FileSystem.createDirectory(directory);
		}
	}

	static function format(value:Float):String
		return value < 0 ? "n/a" : Std.string(Math.round(value * 100.0) / 100.0);

	static function formatBytes(value:Float):String
		return value < 0 ? "n/a" : Std.string(value);
}
