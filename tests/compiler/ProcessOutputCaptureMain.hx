import compiler.ffi.ProcessOutputCapture;

class ProcessOutputCaptureMain {
	static function main():Void {
		var arguments = Sys.args();
		if (arguments.indexOf("--emit-pipe-flood") >= 0) {
			emitPipeFlood();
			return;
		}

		var runtime = option(arguments, "--runtime="),
			program = option(arguments, "--program=");
		if (runtime == null || program == null)
			throw "Process capture test requires --runtime and --program";
		var result = ProcessOutputCapture.capture(runtime, [program, "--emit-pipe-flood"], 4096, 10);
		expect(result.exitCode == 0, 'flood child should exit successfully: ${result.exitCode}');
		expect(result.stdout.length == 256 * 1024, "stdout should be completely drained while stderr is full");
		expect(result.stderr.length == 4096 && result.stderrTruncated, "stderr capture should be bounded while excess bytes are still drained");
		Sys.println("PASS: subprocess output capture drains both pipes and bounds diagnostics");
	}

	static function option(arguments:Array<String>, prefix:String):Null<String> {
		for (argument in arguments)
			if (StringTools.startsWith(argument, prefix))
				return argument.substring(prefix.length);
		return null;
	}

	static function emitPipeFlood():Void {
		var chunkBuilder = new StringBuf();
		for (_ in 0...4096)
			chunkBuilder.add("e");
		var chunk = chunkBuilder.toString();
		for (_ in 0...64)
			Sys.stderr().writeString(chunk);
		Sys.stderr().flush();
		for (_ in 0...64)
			Sys.stdout().writeString(chunk);
		Sys.stdout().flush();
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
