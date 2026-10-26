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
 * (default 90) without a request, since its heap stays at the high-water mark of its largest compile. A watch session
 * keeps its worker by sending keepalive pings (see `CompilerClient.keepWorkersAlive`), so a long pause in a live session
 * does not cost the next edit a cold compile, and a session that ends or dies stops pinging and frees the worker.
 */
class CompilerServer {
	/** 32 random bytes as hex; Windows has no /dev/urandom, so it uses the runtime's BCryptGenRandom. */
	static function secureToken():String {
		if (Sys.systemName() == "Windows")
			return windowsSecureToken();
		var random = File.read("/dev/urandom", true),
			token = random.read(32).toHex();
		random.close();
		return token;
	}

	#if (hl && !haxeon)
	@:hlNative("haxeon_runtime", "__host_secure_random_token")
	static function windowsSecureToken():String
		return null;
	#else
	static function windowsSecureToken():String
		throw "A secure random token requires the Haxeon runtime";
	#end

	public static function main():Void {
		var args = Sys.args();
		if (args.length != 1)
			throw "CompilerServer requires a rendezvous path";
		serve(args[0]);
	}

	static function serve(statePath:String):Void {
		var token = secureToken();
		var listener = new Socket(), session = new CompilerSession();
		listener.bind(new Host("127.0.0.1"), 0);
		listener.listen(8);
		var idleSeconds = idleTimeout();
		// `idleSeconds` also tells clients how often to ping, and that this worker understands pings.
		var descriptor = Json.stringify({
			port: listener.host().port,
			token: token,
			pid: processId(),
			idleSeconds: idleSeconds
		});
		File.saveContent(statePath + "." + token + ".tmp", descriptor);
		FileSystem.rename(statePath + "." + token + ".tmp", statePath);
		try {
			var running = true;
			var idleDeadline = Sys.time() + idleSeconds;
			while (running) {
				// A live publication's history is recorded once no request has followed it for a moment, off the edit's path.
				var wait = Math.max(0, idleDeadline - Sys.time());
				if (session.hasUnrecordedLiveState())
					wait = Math.min(wait, LIVE_STATE_DELAY_SECONDS);
				if (Socket.select([listener], [], [], wait).read.length == 0) {
					recordLiveState(session);
					if (Sys.time() >= idleDeadline)
						break;
					continue;
				}
				var client = listener.accept(), answered = false;
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
					} else if (request.ping == true) {
						// A watch session is still running; the request only counts as activity. The pinger does not wait for
						// an answer, so none is sent.
						answered = true;
						client.close();
					} else if (request.background == true) {
						// The requester only warms the session (a live run that starts from a module it built before), so it is
						// answered at once and the compile runs to completion with nobody waiting; later requests queue behind it.
						send(client, {status: 0});
						client.close();
						answered = true;
						var started = Sys.time();
						var result = compileConnected(null, cast request.arguments, session);
						recordLiveState(session);
						Sys.println('background compile: ${Math.round((Sys.time() - started) * 1000)} ms, ${result.metrics.retypedFunctions} functions retyped');
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
					if (!answered)
						send(client, {status: 0});
				} catch (error:Dynamic) {
					session.reset();
					if (answered)
						Sys.println("background compile failed: " + Std.string(error));
					else
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
				if (!answered)
					client.close();
				idleDeadline = Sys.time() + idleSeconds;
			}
		} catch (error:Dynamic) {
			Sys.stderr().writeString("Compiler server stopped: " + Std.string(error) + "\n");
		}
		recordLiveState(session);
		listener.close();
		// A concurrent startup may have published a replacement worker.
		try {
			if (File.getContent(statePath) == descriptor)
				FileSystem.deleteFile(statePath);
		} catch (_:Dynamic) {}
	}

	/** A disconnected requester cancels only its own transaction, before the next request is accepted. */
	static function compileConnected(client:Null<Socket>, arguments:Array<String>, session:CompilerSession):compiler.Compiler.CompileResult {
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
			for (suffix in (field == "output" ? [
				"",
				".functions",
				".hli",
				".hlp",
				".live.json",
				".live.json.tmp",
				".live.patch.json",
				".live.patch.json.tmp",
				".live.stamp",
				".live.stamp.tmp",
				".build-id",
				".descriptors",
				".descriptors.json",
				".live.full"
			] : [""]))
				outputs.push({temporary: temporary + suffix, destination: destination + suffix});
		}
		if (request.output != null)
			Reflect.setField(staged, "publishedOutput", request.output);
		var promoted:Map<String, Bool> = [];
		var output = request.output;
		// A live patch is published mid-request, ahead of the module: the destination marker goes first so no host reloads
		// the previous module against the new description, and the patch, description and stamp follow in the host's order.
		var publishEarly = function() {
			if (output == null)
				return;
			if (FileSystem.exists(output + ".live.full"))
				FileSystem.deleteFile(output + ".live.full");
			for (suffix in [".hlp", ".live.patch.json", ".live.json", ".live.stamp"]) {
				var temporary = output + stagingSuffix + suffix;
				if (FileSystem.exists(temporary)) {
					CompilerDriver.replaceFile(temporary, output + suffix);
					promoted.set(suffix, true);
				}
			}
		};
		Thread.create(function() {
			runtime.ThreadName.setCurrent("haxeon.compile");
			try
				result = CompilerDriver.compile(cast staged, message -> {
					cancellation.check();
					var requester = client;
					if (requester != null)
						send(requester, {message: message});
				}, session, cancellation, publishEarly)
			catch (error:Dynamic)
				failure = error;
			done.release();
		});
		// A background compile has no requester to disconnect.
		var disconnected = false, watched = client;
		while (!done.wait(0.05)) {
			if (!disconnected && watched != null)
				try {
					if (Socket.select([watched], [], [], 0).read.length > 0) {
						// No further bytes are part of this protocol; readability means disconnect or invalid input.
						try
							watched.input.readByte()
						catch (_:Dynamic) {}
						disconnected = true;
						cancellation.cancel();
					}
				} catch (_:Dynamic) {
					disconnected = true;
					cancellation.cancel();
				}
		}
		if (!disconnected && watched != null)
			try {
				if (Socket.select([watched], [], [], 0).read.length > 0) {
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
		var markerDestination = request.output + ".live.full";
		if (request.output != null && FileSystem.exists(markerDestination))
			FileSystem.deleteFile(markerDestination);
		for (output in outputs) {
			if (request.output != null
				&& StringTools.startsWith(output.destination, request.output)
				&& promoted.exists(output.destination.substr(request.output.length)))
				continue;
			if (FileSystem.exists(output.temporary))
				CompilerDriver.replaceFile(output.temporary, output.destination);
			else if (StringTools.endsWith(output.destination, ".hlp") && FileSystem.exists(output.destination))
				FileSystem.deleteFile(output.destination);
		}
		return result;
	}

	/** How long a live publication waits for a following request before its history is recorded. */
	static inline final LIVE_STATE_DELAY_SECONDS = 1.0;

	static function recordLiveState(session:CompilerSession):Void {
		if (!session.hasUnrecordedLiveState())
			return;
		var started = Sys.time();
		try {
			if (session.recordLiveState())
				Sys.println('recorded live history: ${Math.round((Sys.time() - started) * 1000)} ms');
		} catch (error:Dynamic) {
			Sys.println("could not record live history: " + Std.string(error));
		}
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
