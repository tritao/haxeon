package build.execution;

import compiler.core.InternalError;
import compiler.core.TextDigest;
import compiler.tools.CompilerServerProtocol;
import haxe.Json;
import haxe.SysTools;
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
	 * The compiler build that names a worker program. A watch memoizes its choice to keep the same compiler across edits.
	 * Replacing a prebuilt program or changing the sources it was built from selects a new worker.
	 */
	public static function workerVersion(command:String, compilerSource:Null<String>, home:String, buildRoot:String,
			profilePort:Null<String>,
			?session:build.BuildSession, ?program:build.AotCompiler.CompilerProgram):String {
		// A request states its passes and checks (`CompileOptions`), so one worker serves every combination of them.
		var roots = compilerRoots(compilerSource),
			programFiles = program == null ? [build.HashLinkPath.executable(home)] : program.command,
			inputs = (program == null ? roots : []).concat(programFiles),
			dependencies:Array<Null<String>> = program == null ? [] : [program.sourceDigest];
		// A checkout's stamp check already walked the stdlib. A release's stamp is checked against its manifest.
		if (program == null || compilerSource == null)
			inputs.push(build.HaxeonSdk.stdlib(home));
		var identity = new ExecutionAction(new ActionId("compiler-session-v10"
			+ (profilePort == null ? "" : ":profile:" + profilePort)
			+ (program != null && program.native ? ":aot" : "")), [], inputs, [], "",
			ExecutionAction.ActionKind.Process(command, roots, home, new Map()));
		if (session == null)
			return ActionFingerprint.compute(identity, buildRoot, Sys.systemName(), dependencies);
		var memoKey = Json.stringify([
			identity.id.key(),
			command,
			compilerSource,
			home,
			buildRoot,
			Sys.systemName(),
			programFiles
		]);
		return session.workerVersion(memoKey, () -> {
			var version = ActionFingerprint.compute(identity, buildRoot, Sys.systemName(), dependencies,
				session.digests);
			Sys.println('haxeon: compiler worker version $version (kept for this watch session)');
			return version;
		});
	}

	/**
	 * Compiles `arguments` in the project's worker. `command` is the pinned Haxe that builds the compiler from `compilerSource`,
	 * which is null for a release: it has only the compiler it ships (`build.AotCompiler.program`).
	 */
	public static function run(command:String, compilerSource:Null<String>, arguments:Array<String>, home:String,
			buildRoot:String, projectRoot:String, output:String, target:String,
			fallback:Void->Int, ?session:build.BuildSession, background:Bool = false):Int {
		// On Windows the interpreted CLI (scripts/haxeon.cmd) starts a worker but never connects to it, so only the
		// compiled CLI uses one there.
		if (ProcessRunner.environmentValue("HAXEON_COMPILER_SERVER") == "0"
			|| (Sys.systemName() != "Linux" && Sys.systemName() != "Mac"
			&& Sys.systemName() != "Windows") #if eval || Sys.systemName() == "Windows" #end)
			return fallback();
		var retried = false;
		while (true) {
			var connection:Null<Connection> = null;
			var release:Null<Void->Void> = null;
			var statePath:Null<String> = null, received = false;
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
				// Only bytecode is shared between projects. A worker's patch baseline belongs to one output.
				var version = workerVersion(command, compilerSource, home, buildRoot, profilePort, session,
					prebuilt),
					key = version + "-"
						+ TextDigest.sha256(Json.stringify([projectRoot, buildRoot, output, target])).substr(0, 16);
				statePath = Path.join([directory, key + ".json"]);
				release = lockSessions(directory);
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
							libraryPath = build.HashLinkPath.libraryPath(home)
								.concat([ProcessRunner.environmentValue(libraryVariable)])
								.filter(value -> value != null && value.length > 0)
								.join(":"),
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
				if (session != null && !session.workerPings.exists(statePath))
					session.workerPings.set(statePath, Sys.time());
				var socket = connection.socket;
				socket.setTimeout(600);
				CompilerServerProtocol.writeRequest(socket.output, connection.token,
					background ? Background(arguments) : Compile(arguments));
				release();
				release = null;
				while (true) {
					var response = CompilerServerProtocol.readResponse(socket.input);
					received = true;
					switch response {
						case Message(text):
							build.BuildOutput.line(text);
						case Diagnostics(text):
							build.BuildOutput.error(text);
						case Status(code):
							socket.close();
							connection = null;
							try {
								release = lockSessions(directory);
								retireWorkers(directory, version, key);
							} catch (_:Dynamic) {}
							if (release != null)
								release();
							return code;
					}
				}
			} catch (error:Dynamic) {
				if (release != null)
					release();
				if (connection != null)
					try
						connection.socket.close()
					catch (_:Dynamic) {}
				// A connection queued at idle shutdown closes after the worker drops its rendezvous and saves history.
				if (!retried && !received && connection != null && statePath != null) {
					var state = readState(statePath);
					if (state == null || state.token != connection.token) {
						retried = true;
						continue;
					}
				}
				build.BuildOutput.line("Compiler session unavailable; using one-shot compilation: "
					+ Std.string(error));
				return fallback();
			}
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
		return Math.max(0.25, idleSeconds / 3);
	}

	/** The state a worker published, or null when there is none a client can reach. */
	static function readState(statePath:String):Null<CompilerServerState> {
		var text = try File.getContent(statePath) catch (_:Dynamic) null;
		return text == null ? null : CompilerServerProtocol.decodeState(text);
	}

	static function connect(statePath:String, retirement:Bool = false):Null<Connection> {
		var state = readState(statePath);
		if (state == null || (retirement && !state.canRetire))
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

	#if hl
	@:hlNative("haxeon_runtime", "__host_file_lock_acquire")
	static function acquireSessionLock(path:String):Null<hl.Abstract<"realtime_file_lock">>
		return null;

	@:hlNative("haxeon_runtime", "__host_file_lock_release")
	static function releaseSessionLock(lock:hl.Abstract<"realtime_file_lock">):Void {}
	#end

	/** One OS lock serializes startup and cleanup. Keep its file so callers always lock the same inode. */
	static function lockSessions(directory:String):Void->Void {
		#if hl
		var path = Path.join([directory, "sessions.lock"]), deadline = Sys.time() + 120;
		while (true) {
			var lock = acquireSessionLock(path);
			if (lock != null)
				return () -> releaseSessionLock(lock);
			if (Sys.time() >= deadline)
				throw new InternalError("Timed out waiting for compiler session startup or cleanup");
			Sys.sleep(0.05);
		}
		#else
		return () -> {};
		#end
	}

	/** Publish complete worker bytecode while holding the session lock. */
	static function ensureArtifact(command:String, compilerSource:Null<String>, artifact:String, home:String,
			mainClass:String):Void {
		if (FileSystem.exists(artifact)) {
			if (Sys.systemName() != "Windows")
				Sys.command("touch", ["-c", artifact]);
			return;
		}
		var sources = buildableSources(compilerSource, home),
			temporary = artifact + ".tmp." + Std.string(Std.random(0x3fffffff));
		try {
			var status = ProcessRunner.run(command, build.CompilerSources.classPath(sources).concat([
				"-hl", temporary, "-main", mainClass
			]), home, new Map());
			if (status != 0)
				throw new InternalError("Could not compile " + mainClass);
			FileSystem.rename(temporary, artifact);
		} catch (error:haxe.Exception) {
			if (FileSystem.exists(temporary))
				FileSystem.deleteFile(temporary);
			throw error;
		}
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
	public static function compile(haxe:String, compilerSource:Null<String>, arguments:Array<String>, home:String,
			buildRoot:String,
			projectRoot:String, output:String, target:String, ?session:build.BuildSession):Int
		return run(haxe, compilerSource, arguments, home, buildRoot, projectRoot, output, target,
			() -> runOneShot(haxe, compilerSource, arguments, home, buildRoot, runtimeLibraryEnvironment(home),
			() -> ProcessRunner.run(haxe,
			build.CompilerSources.classPath(buildableSources(compilerSource, home)).concat([
				"--run",
				"compiler.tools.HaxeonCompiler"
			]).concat(arguments), home, new Map())), session);

	/** The roots of the compiler's sources, none for a release. */
	static function compilerRoots(compilerSource:Null<String>):Array<String>
		return compilerSource == null ? [] : build.CompilerSources.roots(compilerSource);

	/** The compiler's sources, to build it from; a release has none, so only the compiler it ships runs there. */
	static function buildableSources(compilerSource:Null<String>, home:String):String {
		if (compilerSource == null)
			throw new InternalError('This Haxeon release has no current compiler to run (${build.AotCompiler.bytecode(home)}); '
				+ "install the release again");
		return compilerSource;
	}

	/** The environment a compiler run by HashLink needs to find its native libraries. */
	public static function runtimeLibraryEnvironment(home:String):Map<String, String> {
		var variable = switch Sys.systemName() {
			case "Windows": "PATH";
			case "Mac": "DYLD_LIBRARY_PATH";
			case _: "LD_LIBRARY_PATH";
		};
		var directories = build.HashLinkPath.libraryPath(home),
			existing = Sys.getEnv(variable);
		if (existing != null && existing.length > 0)
			directories.push(existing);
		var environment = new Map<String, String>();
		environment.set(variable, directories.join(Sys.systemName() == "Windows" ? ";" : ":"));
		return environment;
	}

	public static function runOneShot(command:String, compilerSource:Null<String>, arguments:Array<String>, home:String,
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
					compilerRoots(compilerSource).concat([build.HaxeonSdk.stdlib(home)]), [], "",
					ExecutionAction.ActionKind.Process(command, compilerRoots(compilerSource), home, new Map()));
			artifact = Path.join([
				directory,
				ActionFingerprint.compute(identity, buildRoot, Sys.systemName(), []) + ".hl"
			]);
			var release = lockSessions(directory);
			try {
				ensureArtifact(command, compilerSource, artifact, home, "compiler.tools.HaxeonCompiler");
				removeStaleFiles(directory);
			} catch (error:haxe.Exception) {
				release();
				throw error;
			}
			release();
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
		var path = build.HashLinkPath.libraryPath(home)
			.concat([ProcessRunner.environmentValue("PATH")])
			.filter(value -> value != null && value.length > 0)
			.join(";");
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
		Directories.ensure(directory);
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
		return FileSystem.fullPath(directory);
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
	 * stays and counts against both limits. Live workers retain their normal idle window so an unrelated build cannot
	 * interrupt an edit's patch baseline.
	 */
	static function retireWorkers(directory:String, version:String, currentKey:String):Void {
		var outputSuffix = currentKey.substr(version.length),
			resident:Array<{statePath:String, modified:Float, memory:Float}> = [],
			currentMemory = 0.0;
		var stateName = stateFileName();
		for (entry in FileSystem.readDirectory(directory)) {
			if (!stateName.match(entry))
				continue;
			var statePath = Path.join([directory, entry]),
				memory = workerMemory(statePath);
			if (memory == null && !workerListening(statePath)) {
				// A PID may be invisible in this client's process namespace even while its worker is serving.
				try
					FileSystem.deleteFile(statePath)
				catch (_:Dynamic) {}
				continue;
			}
			if (entry == currentKey + ".json") {
				currentMemory = memory == null ? 0 : memory;
				continue;
			}
			if (StringTools.endsWith(entry, outputSuffix + ".json") && requestRetirement(statePath))
				continue;
			try
				resident.push({
					statePath: statePath,
					modified: FileSystem.stat(statePath).mtime.getTime(),
					memory: memory == null ? 0 : memory
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
			if (count <= limit && total <= budget)
				break;
			if (requestRetirement(worker.statePath)) {
				count--;
				total -= worker.memory;
			}
		}
		removeStaleFiles(directory);
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

	static function stateFileName():EReg
		return ~/^[0-9a-f]{64}-[0-9a-f]{16}\.json$/;

	/** Drops abandoned session files after a day. */
	static function removeStaleFiles(directory:String):Void {
		var entries = FileSystem.readDirectory(directory),
			stateName = stateFileName(),
			programName = ~/^[0-9a-f]{64}\.hl$/,
			logName = ~/^[0-9a-f]{64}-[0-9a-f]{16}\.log$/,
			temporaryName = ~/^[0-9a-f]{64}(\.hl\.tmp\.[0-9]+|-[0-9a-f]{16}\.json\.([0-9a-f]{64}\.tmp|touch\.[0-9]+))$/,
			liveVersions:Map<String, Bool> = [],
			cutoff = (Sys.time() - 24 * 60 * 60) * 1000;
		for (entry in entries) {
			if (!stateName.match(entry))
				continue;
			var path = Path.join([directory, entry]);
			try {
				if (FileSystem.stat(path).mtime.getTime() < cutoff && !workerListening(path)) {
					FileSystem.deleteFile(path);
					continue;
				}
				liveVersions.set(entry.split("-")[0], true);
			} catch (_:Dynamic) {}
		}
		for (entry in entries) {
			var path = Path.join([directory, entry]);
			try {
				var stale = (programName.match(entry) && !liveVersions.exists(Path.withoutExtension(entry)))
					|| (logName.match(entry) && !FileSystem.exists(Path.withExtension(path, "json")))
					|| temporaryName.match(entry);
				if (stale && FileSystem.stat(path).mtime.getTime() < cutoff)
					FileSystem.deleteFile(path);
			} catch (_:Dynamic) {}
		}
	}

	static function workerListening(statePath:String):Bool {
		var connection = connect(statePath);
		if (connection == null)
			return false;
		connection.socket.close();
		return true;
	}

	static function requestRetirement(statePath:String):Bool {
		var connection = connect(statePath, true);
		if (connection == null)
			return false;
		var retired = false;
		try {
			CompilerServerProtocol.writeRequest(connection.socket.output, connection.token, Retire);
			connection.socket.setTimeout(1);
			retired = switch CompilerServerProtocol.readResponse(connection.socket.input) {
				case Status(0): true;
				case _: false;
			};
		} catch (_:Dynamic) {}
		connection.socket.close();
		return retired;
	}
}
