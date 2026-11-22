package build.execution;

import compiler.core.InternalError;
import compiler.tools.CompilerServerProtocol;
import haxe.SysTools;
import haxe.crypto.Sha256;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import sys.net.Host;
import sys.net.Socket;

private typedef Connection = {
	final socket:Socket;
	final token:String;
}

/**
 * Starts/reuses a private project worker. Unsupported hosts retain the one-shot compiler. Workers of every
 * build root share one per-user session directory, so the resident limits bound the whole machine.
 */
class CompilerClient {
	/**
	 * The version that names a worker. Without a session it is fingerprinted on every call; with one it is computed once, and
	 * logged then, so a worker left stale by edits to the compiler sources can be told apart from a fresh one. A worker the
	 * compiler built ahead of time runs (`aot`, `build.AotCompiler`) has a version of its own, so a bytecode worker of the same
	 * sources is not reused once the executable is installed.
	 */
	public static function workerVersion(command:String, compilerSource:String, home:String, buildRoot:String,
			profilePort:Null<String>,
			?session:build.BuildSession, aot:Bool = false):String {
		// A request states its passes and checks (`CompileOptions`), so one worker serves every combination of them.
		var identity = new ExecutionAction(new ActionId("compiler-session-v9"
			+ (profilePort == null ? "" : ":profile:" + profilePort) + (aot ? ":aot" : "")), [],
			build.CompilerSources.roots(compilerSource).concat([Path.join([
				home,
				"stdlib"
			])]), [], "",
			ExecutionAction.ActionKind.Process(command, build.CompilerSources.roots(compilerSource), home,
			new Map()));
		if (session == null)
			return ActionFingerprint.compute(identity, buildRoot, Sys.systemName(), []);
		var memoKey = [identity.id.key(), command, compilerSource, home, buildRoot, Sys.systemName()].join("\n");
		return session.workerVersion(memoKey, () -> {
			var version = ActionFingerprint.compute(identity, buildRoot, Sys.systemName(), [], session.digests);
			Sys.println('haxeon: compiler worker version $version (kept for this watch session)');
			return version;
		});
	}

	public static function run(command:String, compilerSource:String, arguments:Array<String>, home:String,
			buildRoot:String, projectRoot:String,
			fallback:Void->Int, ?session:build.BuildSession, background:Bool = false):Int {
		// On Windows the interpreted CLI (scripts/haxeon.cmd) starts a worker but never connects to it, so only the
		// compiled CLI uses one there.
		if (ProcessRunner.environmentValue("HAXEON_COMPILER_SERVER") == "0"
			|| (Sys.systemName() != "Linux" && Sys.systemName() != "Mac"
			&& Sys.systemName() != "Windows") #if eval || Sys.systemName() == "Windows" #end)
			return fallback();
		var connection:Null<Connection> = null;
		try {
			var profilePort = ProcessRunner.environmentValue("HAXEON_COMPILER_PROFILE_PORT");
			if (profilePort != null
				&& (Std.parseInt(profilePort) == null || Std.parseInt(profilePort) < 1
				|| Std.parseInt(profilePort) > 65535))
				throw new InternalError("HAXEON_COMPILER_PROFILE_PORT must be a TCP port from 1 to 65535");
			var directory = preparedSessionDirectory();
			// The compiler built ahead of time serves when it is current, else a release's compiler bytecode
			// (`build.AotCompiler.program`). A profiled worker runs bytecode built here, with the VM's diagnostics port.
			var prebuilt = profilePort == null ? build.AotCompiler.program(home, compilerSource,
				session == null ? null : session.digests) : null;
			// Changes to the compiler, runtime sources, or launch environment select a new worker.
			// The worker program depends only on the compiler, so every project shares one artifact; each
			// project (and build root) gets its own worker process so it keeps its incremental compiler state.
			var version = workerVersion(command, compilerSource, home, buildRoot, profilePort, session,
				prebuilt != null && prebuilt.native),
				key = version + "-" + Sha256.encode(projectRoot + "\n" + buildRoot).substr(0, 16),
				statePath = Path.join([directory, key + ".json"]);
			connection = connect(statePath);
			if (connection == null) {
				var logPath = Path.join([directory, key + ".log"]),
					// The worker program, to which the state path is the last argument.
					program:Array<String>;
				if (prebuilt != null)
					program = prebuilt.command.concat(["serve"]);
				else {
					var workerArtifact = Path.join([directory, version + ".hl"]);
					ensureArtifact(command, compilerSource, workerArtifact, home, "compiler.tools.CompilerServer");
					program = [build.HashLinkPath.executable(home)];
					if (profilePort != null) {
						program.push("--diagnostics");
						program.push(profilePort);
					}
					program.push(workerArtifact);
				}
				if (Sys.systemName() == "Windows") {
					if (startWindowsWorker(home, program.concat([statePath]), logPath) != 0)
						throw new InternalError("Could not start compiler worker");
				} else {
					var libraryVariable = Sys.systemName() == "Mac" ? "DYLD_LIBRARY_PATH" : "LD_LIBRARY_PATH",
						libraryPath = [
							Path.join([home, "out"]),
							build.HashLinkPath.directory(home),
							ProcessRunner.environmentValue(libraryVariable)
						].filter(value -> value != null && value.length > 0).join(":"),
						launch = program.concat([statePath]).map(SysTools.quoteUnixArg).join(" ");
					// The shell redirects its own three streams first, so neither the worker nor the subshell that
					// `&` makes of the command list (which outlives the build on macOS, where nothing detaches the
					// worker) can keep the caller's pipes open after the build exits.
					var detach = Sys.systemName() == "Linux" ? "setsid -f " : "",
						status = Sys.command("sh", [
							"-c",
							"exec < /dev/null > " + SysTools.quoteUnixArg(logPath) + " 2>&1; umask 077; cd "
								+ SysTools.quoteUnixArg(home)
								+ " && export "
								+ libraryVariable
								+ "="
								+ SysTools.quoteUnixArg(libraryPath) // A resident compiler allocates about 90 GB while compiling an app and keeps ~1.5 GB live. Collecting
								// once the heap has grown by 40% of itself, not HashLink's 20%, runs a third as many major collections
								// (cold app compile: 12 s of GC to 5 s) for about 0.5 GB more resident memory. An explicit setting wins.
								// The shell ignores SIGHUP for the worker instead of nohup: macOS strips DYLD_* from what a system
								// binary such as nohup starts, and the worker would start without the runtime's library path.
								+ " && export HL_GC_MARK_THRESHOLD=\"${HL_GC_MARK_THRESHOLD:-0.4}\" && trap '' HUP && "
								+ detach
								+ launch
								+ " &"
						]);
					if (status != 0)
						throw new InternalError("Could not start compiler worker");
				}
				var deadline = Sys.time() + 30;
				while (connection == null && Sys.time() < deadline) {
					Sys.sleep(0.05);
					connection = connect(statePath);
				}
				if (connection == null)
					throw new InternalError("Compiler worker did not become ready; see " + logPath);
			}
			retireWorkers(directory, version, key);
			markUsed(statePath);
			if (session != null && !session.workerPings.exists(statePath))
				session.workerPings.set(statePath, Sys.time());
			var socket = connection.socket;
			socket.setTimeout(600);
			CompilerServerProtocol.writeRequest(socket.output, connection.token,
				background ? Background(arguments) : Compile(arguments));
			while (true)
				switch CompilerServerProtocol.readResponse(socket.input) {
					case Message(text):
						build.BuildOutput.line(text);
					case Diagnostics(text):
						build.BuildOutput.error(text);
					case Status(code):
						socket.close();
						markUsed(statePath);
						return code;
				}
		} catch (error:Dynamic) {
			if (connection != null)
				try
					connection.socket.close()
				catch (_:Dynamic) {}
			build.BuildOutput.line("Compiler session unavailable; using one-shot compilation: " + Std.string(error));
			return fallback();
		}
	}

	/**
	 * Pings each worker a session uses once a third of its idle timeout has passed, so a watch session keeps its warm worker
	 * for as long as it runs. A ping is a request that does nothing, sent without waiting for an answer: a worker busy
	 * compiling reads it from its accept queue later, and an inherited copy of a socket cannot keep a worker alive the way an
	 * open connection would, so once the session ends or dies its workers exit within their idle timeout. A worker that is
	 * gone is forgotten; the next build starts a new one and registers it again.
	 */
	public static function keepWorkersAlive(session:build.BuildSession):Void {
		var now = Sys.time();
		for (statePath in [for (path in session.workerPings.keys()) path]) {
			var due = session.workerPings.get(statePath);
			if (due != null && due > now)
				continue;
			var interval = pingWorker(statePath);
			if (interval == null)
				session.workerPings.remove(statePath);
			else
				session.workerPings.set(statePath, now + interval);
		}
	}

	/** Pings one worker; the seconds until the next ping is due, or null when no worker that understands pings answers. */
	static function pingWorker(statePath:String):Null<Float> {
		var state = readState(statePath);
		// A worker from before pings would take one for a compile request.
		if (state == null || state.idleSeconds <= 0)
			return null;
		var idleSeconds = state.idleSeconds;
		var connection = connect(statePath);
		if (connection == null)
			return null;
		try {
			CompilerServerProtocol.writeRequest(connection.socket.output, connection.token, Ping);
			connection.socket.close();
		} catch (_:Dynamic) {
			try
				connection.socket.close()
			catch (_:Dynamic) {}
			return null;
		}
		// The worker this session uses stays the most recently used, so retirement takes others first.
		markUsed(statePath);
		return Math.max(0.25, idleSeconds / 3);
	}

	/** The state a worker published, or null when there is none a client can reach. */
	static function readState(statePath:String):Null<CompilerServerState> {
		var text = try File.getContent(statePath) catch (_:Dynamic) null;
		return text == null ? null : CompilerServerProtocol.decodeState(text);
	}

	static function connect(statePath:String):Null<Connection> {
		var state = readState(statePath);
		if (state == null)
			return null;
		var socket:Null<Socket> = null;
		try {
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
	 * On Linux and macOS each use refreshes its modification time, so stale-file cleanup only removes programs nobody
	 * runs. Windows has no touch, so there an unused program is removed by age; the current version's program and any a
	 * running worker uses are always kept.
	 */
	static function ensureArtifact(command:String, compilerSource:String, artifact:String, home:String,
			mainClass:String):Void {
		#if (target.threaded && !eval)
		artifactMutex.acquire();
		#end
		try {
			if (FileSystem.exists(artifact)) {
				if (Sys.systemName() != "Windows")
					Sys.command("touch", ["-c", artifact]);
			} else {
				// Build beside the target and rename, so another Haxeon process never sees a partial file.
				var temporary = artifact + ".tmp." + Std.string(Std.random(1000000)),
					compileStatus = ProcessRunner.run(command, build.CompilerSources.classPath(compilerSource).concat([
						"-hl",
						temporary,
						"-main",
						mainClass
					]), home,
						new Map());
				if (compileStatus != 0)
					throw new InternalError("Could not compile " + mainClass);
				FileSystem.rename(temporary, artifact);
			}
		} catch (error:haxe.Exception) {
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
	/**
	 * Compiles as every `haxeon` command does: in the project's resident compile server, else in a one-shot HashLink build of the
	 * compiler, else in the compiler interpreted by the pinned Haxe (`haxe`). The arguments are the compiler's own
	 * (`CompilerArguments`).
	 */
	public static function compile(haxe:String, compilerSource:String, arguments:Array<String>, home:String,
			buildRoot:String,
			projectRoot:String, ?session:build.BuildSession):Int
		return run(haxe, compilerSource, arguments, home, buildRoot, projectRoot,
			() -> runOneShot(haxe, compilerSource, arguments, home, buildRoot, runtimeLibraryEnvironment(home),
			() -> ProcessRunner.run(haxe, build.CompilerSources.classPath(compilerSource).concat([
				"--run",
				"compiler.tools.HaxeonCompiler"
			]).concat(arguments), home, new Map())), session);

	/** The environment a compiler run by HashLink needs to find its native libraries. */
	public static function runtimeLibraryEnvironment(compilerHome:String):Map<String, String> {
		var variable = switch Sys.systemName() {
			case "Windows": "PATH";
			case "Mac": "DYLD_LIBRARY_PATH";
			case _: "LD_LIBRARY_PATH";
		};
		var directories = [
			haxe.io.Path.join([compilerHome, "out"]),
			build.HashLinkPath.directory(compilerHome)
		],
			existing = Sys.getEnv(variable);
		if (existing != null && existing.length > 0)
			directories.push(existing);
		var environment = new Map<String, String>();
		environment.set(variable, directories.join(Sys.systemName() == "Windows" ? ";" : ":"));
		return environment;
	}

	public static function runOneShot(command:String, compilerSource:String, arguments:Array<String>, home:String,
			buildRoot:String,
			environment:Map<String, String>, fallback:Void->Int):Int {
		// The compiler built ahead of time, or a release's bytecode, when it is current, on every platform.
		var prebuilt = build.AotCompiler.program(home, compilerSource);
		if (prebuilt != null)
			return ProcessRunner.run(prebuilt.command[0], prebuilt.command.slice(1).concat(arguments), home,
				environment);
		if (Sys.systemName() != "Linux" && Sys.systemName() != "Mac")
			return fallback();
		var hashlink = Path.join([build.HashLinkPath.directory(home), "hl"]),
			artifact:String;
		try {
			if (!FileSystem.exists(hashlink))
				throw new InternalError("missing " + hashlink);
			var directory = preparedSessionDirectory(),
				identity = new ExecutionAction(new ActionId("compiler-one-shot-v1"), [],
					build.CompilerSources.roots(compilerSource).concat([Path.join([
						home,
						"stdlib"
					])]), [], "",
					ExecutionAction.ActionKind.Process(command, build.CompilerSources.roots(compilerSource), home,
					new Map()));
			artifact = Path.join([
				directory,
				ActionFingerprint.compute(identity, buildRoot, Sys.systemName(), []) + ".hl"
			]);
			ensureArtifact(command, compilerSource, artifact, home, "compiler.tools.HaxeonCompiler");
		} catch (error:Dynamic) {
			build.BuildOutput.line("Compiled one-shot compiler unavailable; interpreting the compiler: "
				+ Std.string(error));
			return fallback();
		}
		return ProcessRunner.run(hashlink, [artifact].concat(arguments), home, environment);
	}

	/**
		Windows has no setsid or nohup. `start /b` returns at once, and redirecting all three streams
		keeps the worker from holding the build's pipes open.
	**/
	static function startWindowsWorker(home:String, launchArguments:Array<String>, logPath:String):Int {
		var quote = (value:String) -> '"' + value + '"';
		var path = [
			Path.join([home, "out"]),
			build.HashLinkPath.directory(home),
			ProcessRunner.environmentValue("PATH")
		].filter(value -> value != null && value.length > 0).join(";");
		var launch = launchArguments.map(quote);
		var threshold = ProcessRunner.environmentValue("HL_GC_MARK_THRESHOLD");
		return Sys.command('cd /d ${quote(home)} && set "PATH=$path" && set "HL_GC_MARK_THRESHOLD='
			+ (threshold == null || threshold.length == 0 ? "0.4" : threshold)
			+ '" && start "" /b '
			+ launch.join(" ")
			+ " > "
			+ quote(logPath)
			+ " 2>&1 < nul");
	}

	/** The session directory, created private to this user. */
	static function preparedSessionDirectory():String {
		var directory = sessionDirectory(), configured = ProcessRunner.environmentValue("HAXEON_COMPILER_SESSION_DIR");
		FileSystem.createDirectory(directory);
		if (Sys.systemName() != "Windows") {
			if (Sys.command("chmod", ["700", directory]) != 0)
				throw new InternalError("Could not make the compiler session directory private");
		} else if (configured != null && configured.length > 0) {
			// The default under %LOCALAPPDATA% is private already; a configured directory may be shared, so keep only
			// this user's access, as chmod 700 does.
			var user = ProcessRunner.environmentValue("USERNAME");
			if (user == null || Sys.command("icacls", [
				directory,
				"/inheritance:r",
				"/grant:r",
				user + ":(OI)(CI)F",
				"/q"
			]) != 0)
				throw new InternalError("Could not make the compiler session directory private");
		}
		return directory;
	}

	/** The per-user directory holding worker programs, connection metadata, and logs. */
	static function sessionDirectory():String {
		var configured = ProcessRunner.environmentValue("HAXEON_COMPILER_SESSION_DIR");
		if (configured != null && configured.length > 0)
			return configured;
		var local = Sys.systemName() == "Windows" ? ProcessRunner.environmentValue("LOCALAPPDATA") : null;
		if (local != null && local.length > 0)
			return Path.join([local, "haxeon", "compiler"]);
		var cache = ProcessRunner.environmentValue("XDG_CACHE_HOME");
		if (cache == null || cache.length == 0)
			cache = Path.join([
				ProcessRunner.environmentValue(Sys.systemName() == "Windows" ? "USERPROFILE" : "HOME"),
				".cache"
			]);
		return Path.join([cache, "haxeon", "compiler"]);
	}

	static function positiveSetting(name:String, fallback:Int):Int {
		var value = ProcessRunner.environmentValue(name),
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
				resident.push({
					statePath: statePath,
					modified: FileSystem.stat(statePath).mtime.getTime(),
					memory: memory
				})
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
		var state = readState(statePath);
		if (state == null)
			return 0;
		var pid = state.pid;
		if (pid == null)
			return 0;
		try {
			var process = "/proc/" + pid;
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
		} catch (error:haxe.Exception) {
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
			CompilerServerProtocol.writeRequest(connection.socket.output, connection.token, Shutdown);
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
