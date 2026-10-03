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

/**
 * Starts/reuses a private project worker. Unsupported hosts retain the one-shot compiler. Workers of every
 * build root share one per-user session directory, so the resident limits bound the whole machine.
 */
class CompilerClient {
	/** Optimization switches are read once at startup, so each combination needs a separate worker. */
	static function inlineOption():String
		return (Sys.getEnv("HAXEON_INLINE") == "0" ? "off" : "on") + ":loadstore=" + (Sys.getEnv("HAXEON_LOADSTORE") == "0" ? "off" : "on");

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
			var directory = preparedSessionDirectory();
			// Changes to the compiler, runtime sources, or launch environment select a new worker.
			// The worker program depends only on the compiler, so every project shares one artifact; each
			// project (and build root) gets its own worker process so it keeps its incremental compiler state.
			var identity = new ExecutionAction(new ActionId("compiler-session-v8:inline=" + inlineOption()
				+ (profilePort == null ? "" : ":profile:" + profilePort)), [],
				[compilerSource, Path.join([home, "stdlib"])], [], "", ExecutionAction.ActionKind.Process(command, [compilerSource], home, new Map())),
				version = ActionFingerprint.compute(identity, buildRoot, Sys.systemName(), []),
				key = version + "-" + Sha256.encode(projectRoot + "\n" + buildRoot).substr(0, 16),
				statePath = Path.join([directory, key + ".json"]);
			connection = connect(statePath);
			if (connection == null) {
				var workerArtifact = Path.join([directory, version + ".hl"]),
					hashlink = Path.join([home, ".tools", "hashlink", "hl"]),
					logPath = Path.join([directory, key + ".log"]);
				ensureArtifact(command, compilerSource, workerArtifact, home, "compiler.tools.CompilerServer");
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

	/**
	 * Compiles one compiler program once per compiler version; concurrent callers wait for the first to finish.
	 * Each use refreshes its modification time, so stale-file cleanup only removes programs nobody runs.
	 */
	static function ensureArtifact(command:String, compilerSource:String, artifact:String, home:String, mainClass:String):Void {
		#if (target.threaded && !eval)
		artifactMutex.acquire();
		#end
		try {
			if (FileSystem.exists(artifact)) {
				Sys.command("touch", ["-c", artifact]);
			} else {
				// Build beside the target and rename, so another Haxeon process never sees a partial file.
				var temporary = artifact + ".tmp." + Std.string(Std.random(1000000)),
					compileStatus = ProcessRunner.run(command, ["-cp", compilerSource, "-hl", temporary, "-main", mainClass], home, new Map());
				if (compileStatus != 0)
					throw "Could not compile " + mainClass;
				FileSystem.rename(temporary, artifact);
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

	/**
	 * Compiles once without a resident worker by running the compiler as a HashLink program, which is several
	 * times faster than interpreting it. `fallback` (the interpreter) remains for hosts without that path.
	 */
	public static function runOneShot(command:String, compilerSource:String, arguments:Array<String>, home:String, buildRoot:String,
			environment:Map<String, String>, fallback:Void->Int):Int {
		if (Sys.systemName() != "Linux" && Sys.systemName() != "Mac")
			return fallback();
		var hashlink = Path.join([home, ".tools", "hashlink", "hl"]),
			artifact:String;
		try {
			if (!FileSystem.exists(hashlink))
				throw "missing " + hashlink;
			var directory = preparedSessionDirectory(),
				identity = new ExecutionAction(new ActionId("compiler-one-shot-v1"), [], [compilerSource, Path.join([home, "stdlib"])], [], "",
					ExecutionAction.ActionKind.Process(command, [compilerSource], home, new Map()));
			artifact = Path.join([
				directory,
				ActionFingerprint.compute(identity, buildRoot, Sys.systemName(), []) + ".hl"
			]);
			ensureArtifact(command, compilerSource, artifact, home, "compiler.tools.HaxeonCompiler");
		} catch (error:Dynamic) {
			Sys.println("Compiled one-shot compiler unavailable; interpreting the compiler: " + Std.string(error));
			return fallback();
		}
		return ProcessRunner.run(hashlink, [artifact].concat(arguments), home, environment);
	}

	/** The session directory, created private to this user. */
	static function preparedSessionDirectory():String {
		var directory = sessionDirectory();
		FileSystem.createDirectory(directory);
		if (Sys.command("chmod", ["700", directory]) != 0)
			throw "Could not make the compiler session directory private";
		return directory;
	}

	/** The per-user directory holding worker programs, connection metadata, and logs. */
	static function sessionDirectory():String {
		var configured = Sys.getEnv("HAXEON_COMPILER_SESSION_DIR");
		if (configured != null && configured.length > 0)
			return configured;
		var cache = Sys.getEnv("XDG_CACHE_HOME");
		if (cache == null || cache.length == 0)
			cache = Path.join([Sys.getEnv("HOME"), ".cache"]);
		return Path.join([cache, "haxeon", "compiler"]);
	}

	static function positiveSetting(name:String, fallback:Int):Int {
		var value = Sys.getEnv(name),
			parsed = value == null ? null : Std.parseInt(value);
		return parsed == null || parsed < 1 ? fallback : parsed;
	}

	/**
	 * Retires workers that can never be reused (another compiler version for this same project), then the
	 * least recently used workers until at most `HAXEON_COMPILER_WORKERS` stay resident and, where resident
	 * memory is observable, their total stays within `HAXEON_COMPILER_MEMORY_MB`. The current worker always
	 * stays and counts against both limits. Workers are never probed with a bare connection: one that drops
	 * without a request makes the worker reset its incremental state.
	 */
	static function retireWorkers(directory:String, version:String, currentKey:String):Void {
		var projectSuffix = currentKey.substr(version.length),
			resident:Array<{statePath:String, modified:Float, memory:Float}> = [],
			liveVersions = [version => true],
			currentMemory = 0.0;
		for (entry in FileSystem.readDirectory(directory)) {
			if (!StringTools.endsWith(entry, ".json"))
				continue;
			var statePath = Path.join([directory, entry]),
				memory = workerMemory(statePath);
			if (memory == null) {
				// The recorded process is gone, so nothing will ever answer on this state file.
				try
					FileSystem.deleteFile(statePath)
				catch (_:Dynamic) {}
				continue;
			}
			if (entry == currentKey + ".json") {
				currentMemory = memory;
				continue;
			}
			if (!StringTools.startsWith(entry, version + "-") && StringTools.endsWith(entry, projectSuffix + ".json")) {
				shutdownWorker(statePath);
				continue;
			}
			try
				resident.push({statePath: statePath, modified: FileSystem.stat(statePath).mtime.getTime(), memory: memory})
			catch (_:Dynamic) {}
		}
		resident.sort((left, right) -> left.modified < right.modified ? -1 : (left.modified > right.modified ? 1 : 0));
		var limit = positiveSetting("HAXEON_COMPILER_WORKERS", 4),
			budget = positiveSetting("HAXEON_COMPILER_MEMORY_MB", 4096) * 1024.0 * 1024.0,
			count = resident.length + 1,
			total = currentMemory;
		for (worker in resident)
			total += worker.memory;
		for (worker in resident) {
			if (count <= limit && total <= budget) {
				liveVersions.set(Path.withoutExtension(Path.withoutDirectory(worker.statePath)).split("-")[0], true);
				continue;
			}
			shutdownWorker(worker.statePath);
			count--;
			total -= worker.memory;
		}
		removeStaleFiles(directory, liveVersions);
	}

	/**
	 * Resident bytes of the worker a state file describes: 0 when it cannot be measured, null when the
	 * recorded process no longer exists (or its pid now belongs to another program).
	 */
	static function workerMemory(statePath:String):Null<Float> {
		if (Sys.systemName() != "Linux")
			return 0;
		try {
			var state:Dynamic = Json.parse(File.getContent(statePath));
			if (!Std.isOfType(state.pid, Int))
				return 0;
			var process = "/proc/" + state.pid;
			if (!FileSystem.exists(process))
				return null;
			var commandLine = readProcFile(process + "/cmdline");
			if (commandLine.indexOf(Path.withoutDirectory(statePath)) < 0)
				return null;
			for (line in readProcFile(process + "/status").split("\n"))
				if (StringTools.startsWith(line, "VmRSS:")) {
					var kilobytes = Std.parseFloat(StringTools.trim(line.substr(6)).split(" ")[0]);
					return Math.isNaN(kilobytes) ? 0 : kilobytes * 1024;
				}
			return 0;
		} catch (_:Dynamic) {
			return 0;
		}
	}

	/**
	 * Reads a procfs file, whose reported size is zero, by streaming it. NUL separators become spaces,
	 * since HashLink strings end at the first NUL.
	 */
	static function readProcFile(path:String):String {
		var input = File.read(path, true);
		try {
			var bytes = input.readAll();
			for (index in 0...bytes.length)
				if (bytes.get(index) == 0)
					bytes.set(index, " ".code);
			var text = bytes.toString();
			input.close();
			return text;
		} catch (error:Dynamic) {
			input.close();
			throw error;
		}
	}

	/** Drops compiler programs no worker runs and nobody used for a day, and logs of workers gone for a day. */
	static function removeStaleFiles(directory:String, liveVersions:Map<String, Bool>):Void {
		var cutoff = (Sys.time() - 24 * 60 * 60) * 1000;
		for (entry in FileSystem.readDirectory(directory)) {
			var path = Path.join([directory, entry]);
			try {
				var extension = Path.extension(entry),
					stale = (extension == "hl" && !liveVersions.exists(Path.withoutExtension(entry)))
						|| (extension == "log" && !FileSystem.exists(Path.withExtension(path, "json")));
				if (stale && FileSystem.stat(path).mtime.getTime() < cutoff)
					FileSystem.deleteFile(path);
			} catch (_:Dynamic) {}
		}
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
