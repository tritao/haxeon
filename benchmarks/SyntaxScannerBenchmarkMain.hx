package;

import compiler.Source.SourceFile;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.syntax.SyntaxScanner;
import compiler.syntax.SyntaxTree.ParserMode;
import haxe.Json;
import sys.FileSystem;
import sys.io.File;

private typedef Percentiles = {
	final median:Float;
	final p95:Float;
	final p99:Float;
}

/** Baseline for compiler-only versus retained tooling lexical representations. */
class SyntaxScannerBenchmarkMain {
	static function main():Void {
		var args = Sys.args(),
			iterations = intArg(args, "--iterations", 100),
			warmup = intArg(args, "--warmup", 10),
			output = stringArg(args, "--json", "out/syntax-scanner-benchmark.json"),
			checkBudgets = hasFlag(args, "--check-budgets"),
			file = new SourceFile("SyntaxScannerBenchmark.hx", sampleSource());
		if (iterations < 1 || warmup < 0)
			throw "iterations must be positive and warmup cannot be negative";
		for (_ in 0...warmup) {
			new Lexer(file).tokenize();
			new SyntaxScanner(file).scan();
			new Parser(new Lexer(file).tokenize()).parseProgram();
			new Parser(new Lexer(file).tokenize(), null, ParserMode.Cst(file)).parseProgram();
		}

		var compilerTimes = [], toolingTimes = [], compilerParseTimes = [], cstParseTimes = [], compilerTokens = 0, toolingTokens = 0;
		for (_ in 0...iterations) {
			var started = Sys.time(), compiler = new Lexer(file).tokenize();
			compilerTimes.push((Sys.time() - started) * 1000.0);
			compilerTokens = compiler.length;
			started = Sys.time();
			var tooling = new SyntaxScanner(file).scan();
			toolingTimes.push((Sys.time() - started) * 1000.0);
			toolingTokens = tooling.length;
			started = Sys.time();
			new Parser(new Lexer(file).tokenize()).parseProgram();
			compilerParseTimes.push((Sys.time() - started) * 1000.0);
			started = Sys.time();
			new Parser(new Lexer(file).tokenize(), null, ParserMode.Cst(file)).parseProgram();
			cstParseTimes.push((Sys.time() - started) * 1000.0);
		}

		var report = {
			version: 1,
			iterations: iterations,
			warmup: warmup,
			sourceBytes: file.bytes.length,
			compilerTokens: compilerTokens,
			toolingTokens: toolingTokens,
			compilerMs: percentiles(compilerTimes),
			toolingLosslessMs: percentiles(toolingTimes),
			compilerParseMs: percentiles(compilerParseTimes),
			cstParseMs: percentiles(cstParseTimes)
		};
		var separator = output.lastIndexOf("/");
		if (separator > 0) {
			var directory = output.substring(0, separator);
			if (!FileSystem.exists(directory))
				FileSystem.createDirectory(directory);
		}
		File.saveContent(output, Json.stringify(report, null, "  ") + "\n");
		Sys.println('Compiler tokens: ${compilerTokens}, tooling lossless tokens: ${toolingTokens}');
		Sys.println('Compiler median/p95/p99: ${format(report.compilerMs.median)}/${format(report.compilerMs.p95)}/${format(report.compilerMs.p99)} ms');
		Sys.println('Tooling median/p95/p99: ${format(report.toolingLosslessMs.median)}/${format(report.toolingLosslessMs.p95)}/${format(report.toolingLosslessMs.p99)} ms');
		Sys.println('AST-only parse median/p95/p99: ${format(report.compilerParseMs.median)}/${format(report.compilerParseMs.p95)}/${format(report.compilerParseMs.p99)} ms');
		Sys.println('CST parse median/p95/p99: ${format(report.cstParseMs.median)}/${format(report.cstParseMs.p95)}/${format(report.cstParseMs.p99)} ms');
		if (checkBudgets) {
			if (report.compilerMs.p95 > 100.0)
				throw 'Compiler scanner budget exceeded: ${format(report.compilerMs.p95)} ms > 100 ms';
			if (report.toolingLosslessMs.p95 > 100.0)
				throw 'Tooling scanner budget exceeded: ${format(report.toolingLosslessMs.p95)} ms > 100 ms';
			if (report.compilerParseMs.p95 > 100.0)
				throw 'AST-only parse budget exceeded: ${format(report.compilerParseMs.p95)} ms > 100 ms';
			if (report.cstParseMs.p95 > 100.0)
				throw 'CST parse budget exceeded: ${format(report.cstParseMs.p95)} ms > 100 ms';
			Sys.println("Syntax scanner budget check: passed");
		}
		Sys.println('JSON: $output');
	}

	static function sampleSource():String {
		var output = new StringBuf();
		for (index in 0...64) {
			output.add('// module $index\n');
			output.add('class Type$index<T> {\n');
			output.add('\tpublic var value:T;\n');
			output.add('\tpublic function compute(input:T):T return input;\n');
			output.add('}\n');
			output.add('function use$index():Void { var item = new Type$index<Int>(); item.value; }\n');
		}
		return output.toString();
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

	static function intArg(args:Array<String>, name:String, fallback:Int):Int {
		var value = stringArg(args, name, null);
		return value == null ? fallback : Std.parseInt(value);
	}

	static function stringArg(args:Array<String>, name:String, fallback:Null<String>):Null<String> {
		for (index in 0...args.length - 1)
			if (args[index] == name)
				return args[index + 1];
		return fallback;
	}

	static function hasFlag(args:Array<String>, name:String):Bool
		return args.indexOf(name) >= 0;

	static function format(value:Float):String
		return Std.string(Math.round(value * 100.0) / 100.0);
}
