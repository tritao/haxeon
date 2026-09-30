package build.execution;

import haxe.Json;
import haxe.crypto.Sha256;
import haxe.io.Path;
import haxe.SysTools;
import sys.FileSystem;
import sys.io.File;
import sys.net.Host;
import sys.net.Socket;

private typedef Connection = {final socket:Socket; final token:String;}

/** Starts/reuses a private project worker. Unsupported hosts retain the one-shot compiler. */
class CompilerClient {
	/** The worker reads HAXEON_INLINE once at startup, so a different setting needs a different worker. */
	static function inlineOption():String {
		var value = Sys.getEnv("HAXEON_INLINE");
		return value == null ? "" : value;
	}

	public static function run(command:String, compilerSource:String, arguments:Array<String>, home:String, buildRoot:String, projectRoot:String,
			fallback:Void->Int):Int {
		if (Sys.getEnv("HAXEON_COMPILER_SERVER") == "0" || (Sys.systemName() != "Linux" && Sys.systemName() != "Mac"))
			return fallback();
		var connection:Null<Connection> = null;
		try {
			var profilePort = Sys.getEnv("HAXEON_COMPILER_PROFILE_PORT");
			if (profilePort != null
				&& (Std.parseInt(profilePort) == null || Std.parseInt(profilePort) < 1 || Std.parseInt(profilePort) > 65535))
				throw "HAXEON_COMPILER_PROFILE_PORT must be a TCP port from 1 to 65535";
			var directory = Path.join([buildRoot, ".haxeon", "compiler"]);
			FileSystem.createDirectory(directory);
			if (Sys.command("chmod", ["700", directory]) != 0)
				throw "Could not make the compiler session directory private";
			// Changes to the compiler, runtime sources, or launch environment select a new worker.
			// The worker program depends only on the compiler, so every project shares one artifact; each
			// project gets its own worker process so it keeps its incremental compiler state.
			var identity = new ExecutionAction(new ActionId("compiler-session-v7:inline=" + inlineOption()
				+ (profilePort == null ? "" : ":profile:" + profilePort)), [],
				[compilerSource, Path.join([home, "stdlib"])], [], "", ExecutionAction.ActionKind.Process(command, [compilerSource], home, new Map())),
				version = ActionFingerprint.compute(identity, buildRoot, Sys.systemName(), []),
				key = version + "-" + Sha256.encode(projectRoot).substr(0, 16),
				statePath = Path.join([directory, key + ".json"]);
			connection = connect(statePath);
			if (connection == null) {
				var workerArtifact = Path.join([directory, version + ".hl"]),
					hashlink = Path.join([home, ".tools", "hashlink", "hl"]),
					logPath = Path.join([directory, key + ".log"]);
				ensureWorkerArtifact(command, compilerSource, workerArtifact, home);
				var libraryVariable = Sys.systemName() == "Mac" ? "DYLD_LIBRARY_PATH" : "LD_LIBRARY_PATH",
					libraryPath = [
						Path.join([home, "out"]),
						Path.join([home, ".tools", "hashlink"]),
						Sys.getEnv(libraryVariable)
					].filter(value -> value != null && value.length > 0).join(":"),
					launchArguments = [hashlink];
				if (profilePort != null) {
					launchArguments.push("--diagnostics");
					launchArguments.push(profilePort);
				}
				launchArguments.push(workerArtifact);
				launchArguments.push(statePath);
				var launch = launchArguments.map(SysTools.quoteUnixArg).join(" ");
				// Redirect all three streams so the worker cannot keep the caller's
				// pipes open after the build exits.
				var detach = Sys.systemName() == "Linux" ? "setsid -f " : "",
					status = Sys.command("sh", ["-c",
						"umask 077; cd "
						+ SysTools.quoteUnixArg(home)
						+ " && export "
						+ libraryVariable
						+ "="
						+ SysTools.quoteUnixArg(libraryPath)
						+ " && "
						+ detach
						+ "nohup "
						+ launch
						+ " > "
						+ SysTools.quoteUnixArg(logPath)
						+ " 2>&1 < /dev/null &"]);
				if (status != 0)
					throw "Could not start compiler worker";
				var deadline = Sys.time() + 30;
				while (connection == null && Sys.time() < deadline) {
					Sys.sleep(0.05);
					connection = connect(statePath);
				}
				if (connection == null)
					throw "Compiler worker did not become ready; see " + logPath;
			}
			retireWorkers(directory, version, key);
			markUsed(statePath);
			var socket = connection.socket;
			socket.setTimeout(600);
			var bytes = haxe.io.Bytes.ofString(Json.stringify({token: connection.token, arguments: arguments}));
			socket.output.writeInt32(bytes.length);
			socket.output.write(bytes);
			socket.output.flush();
			while (true) {
				var response:Dynamic = Json.parse(socket.input.readLine());
				if (response.message != null)
					Sys.println(response.message);
				if (response.status != null) {
					socket.close();
					markUsed(statePath);
					return response.status;
				}
			}
		} catch (error:Dynamic) {
			if (connection != null)
				try
					connection.socket.close()
				catch (_:Dynamic) {}
			Sys.println("Compiler session unavailable; using one-shot compilation: " + Std.string(error));
			return fallback();
		}
	}

	static function connect(statePath:String):Null<Connection> {
		var socket:Null<Socket> = null;
		try {
			var state:Dynamic = Json.parse(File.getContent(statePath));
			if (!Std.isOfType(state.port, Int) || state.port <= 0 || state.port > 65535 || !Std.isOfType(state.token, String) || state.token.length != 64)
				return null;
			socket = new Socket();
			socket.setTimeout(0.2);
			socket.connect(new Host("127.0.0.1"), state.port);
			return {socket: socket, token: state.token};
		} catch (_:Dynamic) {
			if (socket != null)
				try
					socket.close()
				catch (_:Dynamic) {}
			return null;
		}
	}

	#if (target.threaded && !eval)
	static final artifactMutex = new sys.thread.Mutex();
	#end

	/** Compiles the worker program once per compiler version; concurrent callers wait for the first to finish. */
	static function ensureWorkerArtifact(command:String, compilerSource:String, workerArtifact:String, home:String):Void {
		#if (target.threaded && !eval)
		artifactMutex.acquire();
		#end
		try {
			if (!FileSystem.exists(workerArtifact)) {
				// Build beside the target and rename, so another Haxeon process never sees a partial file.
				var temporary = workerArtifact + ".tmp." + Std.string(Std.random(1000000)),
					compileStatus = ProcessRunner.run(command, [
						"-cp",
						compilerSource,
						"-hl",
						temporary,
						"-main",
						"compiler.tools.CompilerServer"
					], home, new Map());
				if (compileStatus != 0)
					throw "Could not compile the persistent compiler worker";
				FileSystem.rename(temporary, workerArtifact);
			}
		} catch (error:Dynamic) {
			#if (target.threaded && !eval)
			artifactMutex.release();
			#end
			throw error;
		}
		#if (target.threaded && !eval)
		artifactMutex.release();
		#end
	}

	/** Workers kept resident per compiler version before the least recently used one is retired. */
	static function residentLimit():Int {
		var value = Sys.getEnv("HAXEON_COMPILER_WORKERS"),
			parsed = value == null ? null : Std.parseInt(value);
		return parsed == null || parsed < 1 ? 6 : parsed;
	}

	/**
	 * Retires workers of other compiler versions, which can never be reused, and the least recently used
	 * workers beyond the resident limit. Workers of the current version are never probed with a
	 * connection: one that drops without a request makes the worker reset its incremental state.
	 */
	static function retireWorkers(directory:String, version:String, currentKey:String):Void {
		var resident:Array<{statePath:String, modified:Float}> = [];
		for (entry in FileSystem.readDirectory(directory)) {
			if (!StringTools.endsWith(entry, ".json") || entry == currentKey + ".json")
				continue;
			var statePath = Path.join([directory, entry]);
			if (StringTools.startsWith(entry, version + "-"))
				resident.push({statePath: statePath, modified: FileSystem.stat(statePath).mtime.getTime()});
			else
				shutdownWorker(statePath);
		}
		resident.sort((left, right) -> left.modified < right.modified ? -1 : (left.modified > right.modified ? 1 : 0));
		// The current worker counts against the limit as well.
		var excess = resident.length + 1 - residentLimit();
		for (index in 0...(excess > 0 ? excess : 0))
			shutdownWorker(resident[index].statePath);
	}

	/** Refreshes a worker's state file so retirement can order workers by last use. */
	static function markUsed(statePath:String):Void {
		// Replace atomically: a reader that saw a half-written state file would think the worker is gone.
		try {
			var temporary = statePath + ".touch." + Std.string(Std.random(1000000));
			File.saveContent(temporary, File.getContent(statePath));
			FileSystem.rename(temporary, statePath);
		} catch (_:Dynamic) {}
	}

	static function shutdownWorker(statePath:String):Void {
		var connection = connect(statePath);
		if (connection == null) {
			// Nothing is listening, so this state file was left by a worker that already exited.
			try
				FileSystem.deleteFile(statePath)
			catch (_:Dynamic) {}
			return;
		}
		try {
			var request = haxe.io.Bytes.ofString(Json.stringify({token: connection.token, shutdown: true}));
			connection.socket.output.writeInt32(request.length);
			connection.socket.output.write(request);
			connection.socket.output.flush();
			connection.socket.setTimeout(1);
			connection.socket.input.readLine();
			connection.socket.close();
		} catch (_:Dynamic) {
			try
				connection.socket.close()
			catch (_:Dynamic) {}
		}
	}
}
