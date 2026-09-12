package compiler.ffi;

import sys.thread.Thread;
#if haxeon
import sys.thread.Mutex;
#else
import haxe.Timer;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import sys.io.Process;
import sys.thread.Lock;
#end

#if !haxeon
private typedef CapturedBytes = {
	final bytes:Bytes;
	final truncated:Bool;
}
#end

typedef ProcessCaptureResult = {
	final stdout:String;
	final stderr:String;
	final stderrTruncated:Bool;
	final exitCode:Int;
}

/** Captures both subprocess streams and caps the diagnostic text retained in memory. */
class ProcessOutputCapture {
	public static inline final defaultDiagnosticLimit = 64 * 1024;

	public static function capture(command:String, arguments:Array<String>, stderrLimit:Null<Int>, ?timeoutSeconds:Float):ProcessCaptureResult {
		if (stderrLimit != null && stderrLimit < 0)
			throw "Process stderr limit cannot be negative";
		if (timeoutSeconds != null && timeoutSeconds <= 0)
			throw "Process timeout must be positive";
		#if haxeon
		return captureHaxeon(command, arguments, stderrLimit, timeoutSeconds);
		#elseif eval
		// Haxe eval can stall when both blocking Process pipes are read from separate threads.
		if (stderrLimit == null)
			throw "Haxe eval process capture requires a stderr limit";
		if (timeoutSeconds != null)
			throw "Haxe eval process capture does not support timeouts";
		return captureSequential(command, arguments, stderrLimit);
		#else
		var process = new Process(command, arguments),
			stdoutDone = new Lock(),
			stderrDone = new Lock(),
			stdoutBytes:Null<Bytes> = null,
			stderrResult:Null<CapturedBytes> = null,
			stdoutError:Dynamic = null,
			stderrError:Dynamic = null;

		Thread.create(function() {
			try
				stdoutBytes = process.stdout.readAll()
			catch (error:Dynamic) {
				stdoutError = error;
				kill(process);
			}
			stdoutDone.release();
		});
		Thread.create(function() {
			try
				stderrResult = read(process.stderr, stderrLimit)
			catch (error:Dynamic) {
				stderrError = error;
				kill(process);
			}
			stderrDone.release();
		});

		var deadline = timeoutSeconds == null ? null : Timer.stamp() + timeoutSeconds,
			stdoutFinished = waitFor(stdoutDone, deadline),
			stderrFinished = waitFor(stderrDone, deadline),
			timedOut = !stdoutFinished || !stderrFinished;
		if (timedOut) {
			kill(process);
			if (!stdoutFinished)
				stdoutDone.wait();
			if (!stderrFinished)
				stderrDone.wait();
		}

		var exitCode:Null<Int>;
		try
			exitCode = process.exitCode()
		catch (error:Dynamic) {
			process.close();
			throw error;
		}
		process.close();

		if (timedOut)
			throw 'Process "$command" timed out after $timeoutSeconds seconds';
		if (stdoutError != null)
			throw 'Could not read stdout from "$command": $stdoutError';
		if (stderrError != null)
			throw 'Could not read stderr from "$command": $stderrError';
		if (stdoutBytes == null || stderrResult == null || exitCode == null)
			throw 'Process "$command" completed without returning all captured output';

		return {
			stdout: stdoutBytes.toString(),
			stderr: stderrResult.bytes.toString(),
			stderrTruncated: stderrResult.truncated,
			exitCode: exitCode
		};
		#end
	}

	#if haxeon
	static function captureHaxeon(command:String, arguments:Array<String>, stderrLimit:Null<Int>, timeoutSeconds:Null<Float>):ProcessCaptureResult {
		var process = sys.io.Process.run(command, arguments), mutex = new Mutex(), stdout = "", stderr = "", stdoutDone = false, stderrDone = false,
			failure:Dynamic = null;
		Thread.create(function() {
			var error:Dynamic = null;
			try
				stdout = process.readStdout()
			catch (caught:Dynamic)
				error = caught;
			mutex.acquire();
			if (error != null)
				failure = error;
			stdoutDone = true;
			mutex.release();
		});
		Thread.create(function() {
			var error:Dynamic = null;
			try
				stderr = process.readStderr()
			catch (caught:Dynamic)
				error = caught;
			mutex.acquire();
			if (error != null && failure == null)
				failure = error;
			stderrDone = true;
			mutex.release();
		});
		var deadline = timeoutSeconds == null ? 0.0 : Sys.time() + timeoutSeconds;
		var timedOut = false;
		while (true) {
			mutex.acquire();
			var done = stdoutDone && stderrDone;
			mutex.release();
			if (done)
				break;
			if (timeoutSeconds != null && Sys.time() >= deadline) {
				process.kill();
				timedOut = true;
				break;
			}
			Sys.sleep(0.001);
		}
		if (timedOut)
			while (true) {
				mutex.acquire();
				var drained = stdoutDone && stderrDone;
				mutex.release();
				if (drained)
					break;
				Sys.sleep(0.001);
			}
		var exitCode = process.exitCode();
		process.close();
		if (timedOut)
			throw 'Process "$command" timed out after $timeoutSeconds seconds';
		if (failure != null)
			throw 'Could not capture output from "$command": $failure';
		var truncated = false;
		if (stderrLimit != null && stderr.length > stderrLimit) {
			stderr = stderr.substr(0, stderrLimit);
			truncated = true;
		}
		return {
			stdout: stdout,
			stderr: stderr,
			stderrTruncated: truncated,
			exitCode: exitCode
		};
	}
	#end

	#if eval
	static function captureSequential(command:String, arguments:Array<String>, stderrLimit:Int):ProcessCaptureResult {
		var process = new Process(command, arguments),
			stdoutBytes:Null<Bytes> = null,
			stderrResult:Null<CapturedBytes> = null,
			exitCode:Null<Int> = null;
		try {
			stdoutBytes = process.stdout.readAll();
			stderrResult = read(process.stderr, stderrLimit);
			exitCode = process.exitCode();
		} catch (error:Dynamic) {
			kill(process);
			process.close();
			throw 'Could not capture output from "$command": $error';
		}
		process.close();
		if (stdoutBytes == null || stderrResult == null || exitCode == null)
			throw 'Process "$command" completed without returning all captured output';
		return {
			stdout: stdoutBytes.toString(),
			stderr: stderrResult.bytes.toString(),
			stderrTruncated: stderrResult.truncated,
			exitCode: exitCode
		};
	}
	#end

	#if !haxeon
	static function read(input:haxe.io.Input, limit:Null<Int>):CapturedBytes {
		var chunk = Bytes.alloc(16 * 1024),
			captured = new BytesBuffer(),
			capturedLength = 0,
			truncated = false;
		while (true) {
			var length = try input.readBytes(chunk, 0, chunk.length) catch (_:haxe.io.Eof) -1;
			if (length < 0)
				break;
			if (length == 0)
				throw haxe.io.Error.Blocked;
			if (limit == null) {
				captured.addBytes(chunk, 0, length);
				continue;
			}
			var remaining = limit - capturedLength;
			if (remaining > 0) {
				var retained = length < remaining ? length : remaining;
				captured.addBytes(chunk, 0, retained);
				capturedLength += retained;
				if (retained < length)
					truncated = true;
			} else
				truncated = true;
		}
		return {bytes: captured.getBytes(), truncated: truncated};
	}

	static function waitFor(lock:Lock, deadline:Null<Float>):Bool {
		if (deadline == null) {
			lock.wait();
			return true;
		}
		var remaining = deadline - Timer.stamp();
		return remaining > 0 && lock.wait(remaining);
	}

	static function kill(process:Process):Void {
		try
			process.kill()
		catch (_:Dynamic) {}
	}
	#end
}
