package compiler.tools;

import compiler.Diagnostic.CompileError;
import compiler.service.CancellationToken;
import sys.thread.Thread;
import sys.thread.Lock;
import haxe.Json;
import sys.io.File;
import sys.FileSystem;
import sys.net.Host;
import sys.net.Socket;

/**
 * Private loopback worker for one project's build session. Exits after `HAXEON_COMPILER_IDLE_SECONDS`
 * (default 90) without a request, since its heap stays at the high-water mark of its largest compile.
 */
class CompilerServer {
	public static function main():Void {
		var args = Sys.args();
		if (args.length != 1)
			throw "CompilerServer requires a rendezvous path";
		serve(args[0]);
	}

	static function serve(statePath:String):Void {
		var random = File.read("/dev/urandom", true),
			token = random.read(32).toHex();
		random.close();
		var listener = new Socket(), session = new CompilerSession();
		listener.bind(new Host("127.0.0.1"), 0);
		listener.listen(8);
		var descriptor = Json.stringify({port: listener.host().port, token: token, pid: processId()});
		File.saveContent(statePath + "." + token + ".tmp", descriptor);
		FileSystem.rename(statePath + "." + token + ".tmp", statePath);
		try {
			var running = true;
			var idleSeconds = idleTimeout();
			var idleDeadline = Sys.time() + idleSeconds;
			while (running) {
				if (Socket.select([listener], [], [], Math.max(0, idleDeadline - Sys.time())).read.length == 0) {
					if (Sys.time() >= idleDeadline)
						break;
					continue;
				}
				var client = listener.accept();
				client.setTimeout(600);
				try {
					var length = client.input.readInt32();
					if (length <= 0 || length > 8 * 1024 * 1024)
						throw "Invalid compiler request length";
					var request:Dynamic = Json.parse(client.input.readString(length));
					if (request.token != token)
						throw "Invalid compiler session token";
					if (request.shutdown == true) {
						running = false;
					} else {
						var started = Sys.time();
						#if (hl && !haxeon)
						var memoryBefore = hl.Gc.stats();
						#end
						var result = compileConnected(client, cast request.arguments, session);
						#if (hl && !haxeon)
						var memoryAfter = hl.Gc.stats();
						send(client,
							{message: 'worker allocations: bytes=${Math.round(memoryAfter.totalAllocated - memoryBefore.totalAllocated)} count=${Math.round(memoryAfter.allocationCount - memoryBefore.allocationCount)} heap=${Math.round(memoryAfter.currentMemory)}'});
						#end
						send(client,
							{message: 'compiler: ${Math.round((Sys.time() - started) * 1000)} ms, ${result.metrics.retypedFunctions} functions retyped'});
					}
					send(client, {status: 0});
				} catch (error:Dynamic) {
					session.reset();
					try {
						var message = Std.string(error);
						if (Std.isOfType(error, CompileError)) {
							var failure:CompileError = cast error,
								diagnostic = failure.diagnostic;
							message = diagnostic.format();
						}
						send(client, {message: message});
						send(client, {status: 1});
					} catch (_:Dynamic) {}
				}
				client.close();
				idleDeadline = Sys.time() + idleSeconds;
			}
		} catch (error:Dynamic) {
			Sys.stderr().writeString("Compiler server stopped: " + Std.string(error) + "\n");
		}
		listener.close();
		// A concurrent startup may have published a replacement worker.
		try {
			if (File.getContent(statePath) == descriptor)
				FileSystem.deleteFile(statePath);
		} catch (_:Dynamic) {}
	}

	/** A disconnected requester cancels only its own transaction, before the next request is accepted. */
	static function compileConnected(client:Socket, arguments:Array<String>, session:CompilerSession):compiler.Compiler.CompileResult {
		var cancellation = new CancellationToken(), done = new Lock();
		var result:compiler.Compiler.CompileResult = null;
		var failure:Dynamic = null;
		var request = CompilerArguments.parse(arguments);
		// Stage every artifact so cancellation preserves the previous successful publication.
		var staged:Dynamic = Reflect.copy(request);
		var outputs:Array<{temporary:String, destination:String}> = [];
		var stagingSuffix = ".request-" + Std.string(Std.random(0x3fffffff));
		for (field in ["output", "xmlOutput", "irOutput", "ffiHeader"]) {
			var destination:Null<String> = Reflect.field(request, field);
			if (destination == null)
				continue;
			var temporary = destination + stagingSuffix;
			Reflect.setField(staged, field, temporary);
			for (suffix in (field == "output" ? ["", ".functions", ".hli", ".hlp", ".live.json", ".live.json.tmp", ".build-id"] : [""]))
				outputs.push({temporary: temporary + suffix, destination: destination + suffix});
		}
		Thread.create(function() {
			try
				result = CompilerDriver.compile(cast staged, message -> {
					cancellation.check();
					send(client, {message: message});
				}, session, cancellation)
			catch (error:Dynamic)
				failure = error;
			done.release();
		});
		var disconnected = false;
		while (!done.wait(0.05)) {
			if (!disconnected)
				try {
					if (Socket.select([client], [], [], 0).read.length > 0) {
						// No further bytes are part of this protocol; readability means disconnect or invalid input.
						try
							client.input.readByte()
						catch (_:Dynamic) {}
						disconnected = true;
						cancellation.cancel();
					}
				} catch (_:Dynamic) {
					disconnected = true;
					cancellation.cancel();
				}
		}
		if (!disconnected)
			try {
				if (Socket.select([client], [], [], 0).read.length > 0) {
					disconnected = true;
					cancellation.cancel();
				}
			} catch (_:Dynamic) {
				disconnected = true;
				cancellation.cancel();
			}
		if (disconnected || failure != null) {
			for (output in outputs)
				try
					if (FileSystem.exists(output.temporary))
						FileSystem.deleteFile(output.temporary)
				catch (_:Dynamic) {}
			if (disconnected) {
				session.reset();
				cancellation.check();
			}
			throw failure;
		}
		for (output in outputs) {
			if (FileSystem.exists(output.temporary))
				FileSystem.rename(output.temporary, output.destination);
			else if (StringTools.endsWith(output.destination, ".hlp") && FileSystem.exists(output.destination))
				FileSystem.deleteFile(output.destination);
		}
		return result;
	}

	static function idleTimeout():Float {
		var value = Sys.getEnv("HAXEON_COMPILER_IDLE_SECONDS"),
			parsed = value == null ? null : Std.parseInt(value);
		return parsed == null || parsed < 1 ? 90 : parsed;
	}

	/** Lets clients measure and liveness-check this worker without connecting to it. */
	#if hl
	@:hlNative("std", "sys_getpid") static function processId():Int
		return 0;
	#else
	static function processId():Null<Int>
		return null;
	#end

	static function send(client:Socket, value:Dynamic):Void {
		client.output.writeString(Json.stringify(value) + "\n");
		client.output.flush();
	}
}
