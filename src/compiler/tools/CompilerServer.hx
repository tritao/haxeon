package compiler.tools;

import compiler.core.CancellationToken;
import compiler.core.Diagnostic.CompileError;
import compiler.core.InternalError;
import compiler.tools.CompilerServerProtocol;
import sys.FileSystem;
import sys.io.File;
import sys.net.Host;
import sys.net.Socket;
import sys.thread.Lock;
import sys.thread.Thread;

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

	#if hl
	@:hlNative("haxeon_runtime", "__host_secure_random_token")
	static function windowsSecureToken():String
		return null;
	#else
	static function windowsSecureToken():String
		throw new InternalError("A secure random token requires the Haxeon runtime");
	#end

	public static function main():Void {
		var args = Sys.args();
		if (args.length != 1)
			throw new InternalError("CompilerServer requires a rendezvous path");
		serve(args[0]);
	}

	/** Serves requests until idle, publishing how to reach it at `statePath` (the rendezvous `CompilerClient` reads). */
	public static function serve(statePath:String):Void {
		ProcessMemory.compileServer();
		var token = secureToken();
		var listener = new Socket(), session = new CompilerSession();
		listener.bind(new Host("127.0.0.1"), 0);
		listener.listen(32);
		var idleSeconds = idleTimeout();
		// `idleSeconds` also tells clients how often to ping, and that this worker understands pings.
		var descriptor = CompilerServerProtocol.encodeState({
			port: listener.host().port,
			token: token,
			pid: processId(),
			idleSeconds: idleSeconds,
			canRetire: true
		});
		var temporaryState = statePath + "." + token + ".tmp";
		function publishState():Void {
			File.saveContent(temporaryState, descriptor);
			CompilerDriver.replaceFile(temporaryState, statePath);
		}
		publishState();
		var shutdown:Null<Socket> = null, live = false;
		try {
			var running = true;
			var idleDeadline = Sys.time() + idleSeconds;
			while (running) {
				// A live publication's history is recorded once no request has followed it for a while, off the edit's path.
				var wait = Math.max(0, idleDeadline - Sys.time());
				if (session.hasUnrecordedLiveState())
					wait = Math.min(wait, LIVE_STATE_DELAY_SECONDS);
				if (Socket.select([listener], [], [], wait).read.length == 0) {
					recordLiveState(session);
					if (Sys.time() >= idleDeadline)
						break;
					continue;
				}
				var client = listener.accept(), answered = false, activity = false, compiled = false;
				// The request being served, once its arguments parsed: its diagnostics are printed as it asks.
				var request:Null<CompilerRequest> = null;
				client.setTimeout(600);
				try {
					var incoming = CompilerServerProtocol.readRequest(client.input, token);
					activity = true;
					switch incoming {
						case Retire if (live):
							// A budget sweep must not shorten the idle window of a live editing session.
							activity = false;
							send(client, Status(1));
							client.close();
							answered = true;
						case Shutdown | Retire:
							shutdown = client;
							answered = true;
							running = false;
						case Ping:
							// A watch session is still running; the request only counts as activity. The pinger does not wait for
							// an answer, so none is sent.
							answered = true;
							client.close();
						case Background(arguments):
							// The requester only warms the session (a live run that starts from a module it built before), so it is
							// answered at once and the compile runs to completion with nobody waiting; later requests queue behind
							// it.
							send(client, Status(0));
							client.close();
							answered = true;
							var started = Sys.time(), parsed = CompilerArguments.parse(arguments);
							live = live || parsed.live;
							var retyped = compileConnected(null, parsed, session);
							recordLiveState(session);
							Sys.println('background compile: ${Math.round((Sys.time() - started) * 1000)} ms, $retyped functions retyped');
						case Compile(arguments):
							compiled = true;
							var started = Sys.time();
							#if hl
							var memoryBefore = hl.Gc.stats();
							#end
							var parsed = CompilerArguments.parse(arguments);
							request = parsed;
							live = live || parsed.live;
							var retyped = compileConnected(client, parsed, session);
							// The worker's costs, at `detailed`.
							if (parsed.verbosity.atLeast(Verbosity.Detailed)) {
								#if hl
								var memoryAfter = hl.Gc.stats();
								send(client,
									Message('worker allocations: bytes=${WholeNumber.text(memoryAfter.totalAllocated - memoryBefore.totalAllocated)} count=${WholeNumber.text(memoryAfter.allocationCount - memoryBefore.allocationCount)} heap=${WholeNumber.text(memoryAfter.currentMemory)}'));
								#end
								send(client,
									Message('compiler: ${Math.round((Sys.time() - started) * 1000)} ms, $retyped functions retyped'));
							}
					}
					if (activity && running)
						try
							publishState()
						catch (_:Dynamic) {}
					if (!answered)
						send(client, Status(0));
				} catch (error:Dynamic) {
					// A failed compile rolled back its own transaction (`CompilationTransaction`), so the session keeps the last good
					// build and its live history: the edit that fixes the error patches the module the host runs.
					if (answered)
						Sys.println("background compile failed: " + Std.string(error));
					else
						try {
							var failed = request;
							if (Std.isOfType(error, CompileError) && failed != null) {
								var failure:CompileError = cast error;
								send(client, Diagnostics(new DiagnosticPrinter(failed).errors(failure.diagnostics)));
							} else
								send(client, Message(Std.string(error)));
							send(client, Status(1));
						} catch (_:Dynamic) {}
				}
				if (!answered)
					client.close();
				// Only after a compile: a collection after pings would land on the next edit's path.
				if (compiled)
					ProcessMemory.betweenRequests();
				if (activity)
					idleDeadline = Sys.time() + idleSeconds;
			}
		} catch (error:Dynamic) {
			Sys.stderr().writeString("Compiler server stopped: " + Std.string(error) + "\n");
		}
		recordLiveState(session);
		// Keep accepting connections in the kernel until the history is ready for a replacement.
		// Remove the rendezvous before closing, so a new worker can only publish after this deletion.
		try {
			if (File.getContent(statePath) == descriptor)
				FileSystem.deleteFile(statePath);
		} catch (_:Dynamic) {}
		listener.close();
		if (shutdown != null) {
			try
				send(shutdown, Status(0))
			catch (_:Dynamic) {}
			shutdown.close();
		}
	}

	/**
	 * Compiles, or checks (`--no-output`), and returns how many functions were typed again. A disconnected requester cancels only
	 * its own transaction, before the next request is accepted.
	 */
	static function compileConnected(client:Null<Socket>, request:CompilerRequest, session:CompilerSession):Int {
		var cancellation = new CancellationToken(), done = new Lock();
		var retyped = 0;
		var failure:Null<haxe.Exception> = null;
		// Stage every artifact so cancellation preserves the previous successful publication.
		var staged:Dynamic = Reflect.copy(request);
		var outputs:Array<{temporary:String, destination:String}> = [];
		var stagingSuffix = ".request-" + Std.string(Std.random(0x3fffffff));
		for (field in [
			"output",
			"xmlOutput",
			"apiJsonOutput",
			"irOutput",
			"inputsOutput",
			"ffiHeader",
			"baselineOutput",
			"entryIdOutput"
		]) {
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
			var counting = AllocationCensus.begin();
			function progress(message:String):Void {
				cancellation.check();
				var requester = client;
				if (requester != null)
					send(requester, Message(message));
			}
			function diagnostics(message:String):Void {
				var requester = client;
				if (requester != null)
					send(requester, Diagnostics(message));
			}
			try
				retyped = request.noOutput ? CompilerDriver.check(cast staged, progress, session, cancellation,
					diagnostics).retyped.length : CompilerDriver.compile(cast staged, progress, session, cancellation,
					publishEarly, diagnostics).metrics.retypedFunctions
			catch (error:haxe.Exception)
				failure = error;
			if (counting)
				AllocationCensus.end();
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
		// A compile that finished committed its state, so its artifacts are published even when its requester left: the session's
		// next build starts from them.
		if (failure != null) {
			for (output in outputs)
				try
					if (FileSystem.exists(output.temporary))
						FileSystem.deleteFile(output.temporary)
				catch (_:Dynamic) {}
			throw failure;
		}
		CompilerMemoryLog.record(request.output, session);
		if (Sys.getEnv("HAXEON_COMPILER_CENSUS") != null)
			sys.thread.Thread.create(function() CompilerMemoryCensus.run(session));
		// A check wrote nothing to publish.
		if (request.noOutput)
			return retyped;
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
		return retyped;
	}

	/**
		How long a live publication waits for a following request before its history is recorded. Encoding an app's history takes
		seconds and holds the server, so it waits out a pause in editing, not the gap between two saves; a server that exits
		(idle, shut down) records it first, so only a crash loses what has not been recorded, and the next session reloads.
	**/
	static inline final LIVE_STATE_DELAY_SECONDS = 10.0;

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
	#if haxeon
	static function processId():Null<Int>
		return Sys.getPid();
	#elseif hl
	@:hlNative("std", "sys_getpid") static function processId():Int
		return 0;
	#else
	static function processId():Null<Int>
		return null;
	#end

	static function send(client:Socket, response:CompilerServerResponse):Void
		CompilerServerProtocol.writeResponse(client.output, response);
}
