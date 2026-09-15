package;

import compiler.service.LanguageService;
import haxe.Json;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

private typedef Sample = {
	final updateMs:Float;
	final completionMs:Float;
	final signatureMs:Float;
	final totalMs:Float;
}

private typedef Percentiles = {
	final median:Float;
	final p95:Float;
	final p99:Float;
}

/** Measures editor recovery latency and memory growth under rapid edits. */
class LanguageServiceBenchmarkMain {
	static final prefix = "class Foo { public function bar(value:Int):Int return value; }\n" + "function main():Void { var foo:Foo = new Foo(); ";
	static final tails = [
		"f",
		"fo",
		"foo",
		"foo.",
		"foo.b",
		"foo.ba",
		"foo.bar(",
		"foo.bar(x",
		"foo.bar(x)"
	];

	static function main():Void {
		var args = Sys.args(),
			iterations = intArg(args, "--iterations", 100),
			warmup = intArg(args, "--warmup", 10),
			output = stringArg(args, "--json", "out/editor-benchmark.json");
		if (iterations < 1 || warmup < 0)
			throw "iterations must be positive and warmup cannot be negative";

		for (_ in 0...warmup)
			runIteration();
		var before = processMemory(),
			samples = [for (_ in 0...iterations) runIteration()],
			after = processMemory();
		var report = {
			version: 1,
			iterations: iterations,
			warmup: warmup,
			platform: Sys.systemName(),
			memoryBeforeBytes: before,
			memoryAfterBytes: after,
			memoryGrowthBytes: after < 0 || before < 0 ? -1 : after - before,
			updateMs: percentiles([for (sample in samples) sample.updateMs]),
			completionMs: percentiles([for (sample in samples) sample.completionMs]),
			signatureMs: percentiles([for (sample in samples) sample.signatureMs]),
			totalMs: percentiles([for (sample in samples) sample.totalMs])
		};
		var separator = output.lastIndexOf("/");
		if (separator > 0) {
			var directory = output.substring(0, separator);
			if (!FileSystem.exists(directory))
				FileSystem.createDirectory(directory);
		}
		File.saveContent(output, Json.stringify(report, null, "  ") + "\n");
		Sys.println('Editor benchmark: ${iterations} iterations, memory growth ${report.memoryGrowthBytes} bytes');
		Sys.println('Update median/p95/p99: ${format(report.updateMs.median)}/${format(report.updateMs.p95)}/${format(report.updateMs.p99)} ms');
		Sys.println('Completion median/p95/p99: ${format(report.completionMs.median)}/${format(report.completionMs.p95)}/${format(report.completionMs.p99)} ms');
		Sys.println('Signature median/p95/p99: ${format(report.signatureMs.median)}/${format(report.signatureMs.p95)}/${format(report.signatureMs.p99)} ms');
		Sys.println('JSON: $output');
	}

	static function runIteration():Sample {
		var service = new LanguageService(),
			updateMs = 0.0,
			completionMs = 0.0,
			signatureMs = 0.0,
			started = Sys.time();
		for (tail in tails) {
			var source = prefix + tail, editStarted = Sys.time();
			service.update("EditorBenchmark.hx", source);
			updateMs += (Sys.time() - editStarted) * 1000.0;
			var queryStarted = Sys.time();
			service.completeResult("EditorBenchmark.hx", source.length);
			completionMs += (Sys.time() - queryStarted) * 1000.0;
			if (tail == "foo.bar(" || tail == "foo.bar(x") {
				queryStarted = Sys.time();
				service.signatureHelp("EditorBenchmark.hx", source.length);
				signatureMs += (Sys.time() - queryStarted) * 1000.0;
			}
		}
		return {
			updateMs: updateMs,
			completionMs: completionMs,
			signatureMs: signatureMs,
			totalMs: (Sys.time() - started) * 1000.0
		};
	}

	static function percentiles(values:Array<Float>):Percentiles {
		values.sort(Reflect.compare);
		return {
			median: percentile(values, 0.5),
			p95: percentile(values, 0.95),
			p99: percentile(values, 0.99)
		};
	}

	static function percentile(values:Array<Float>, fraction:Float):Float {
		var index = Std.int(Math.ceil(values.length * fraction)) - 1;
		if (index < 0)
			index = 0;
		if (index >= values.length)
			index = values.length - 1;
		return values[index];
	}

	static function processMemory():Float {
		var process:Process = null;
		try {
			process = new Process("sh", ["-c", "ps -o rss= -p $PPID"]);
			var residentKb = Std.parseInt(StringTools.trim(process.stdout.readAll().toString()));
			process.close();
			return residentKb == null ? -1 : residentKb * 1024.0;
		} catch (_:Dynamic) {
			if (process != null)
				process.close();
			return -1;
		}
	}

	static function format(value:Float):String
		return Std.string(Math.round(value * 100.0) / 100.0);

	static function intArg(args:Array<String>, name:String, fallback:Int):Int {
		var value = stringArg(args, name, null);
		return value == null ? fallback : Std.parseInt(value);
	}

	static function stringArg(args:Array<String>, name:String, fallback:Null<String>):Null<String> {
		var prefix = name + "=";
		for (argument in args)
			if (StringTools.startsWith(argument, prefix))
				return argument.substring(prefix.length);
		return fallback;
	}
}
