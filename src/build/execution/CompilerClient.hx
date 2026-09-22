package build.execution;

import haxe.Json;
import haxe.io.Path;
import haxe.SysTools;
import sys.FileSystem;
import sys.io.File;
import sys.net.Host;
import sys.net.Socket;

private typedef Connection = {final socket:Socket; final token:String;}

/** Starts/reuses a private project worker. Unsupported hosts retain the one-shot compiler. */
class CompilerClient {
	public static function run(command:String, compilerSource:String, arguments:Array<String>, home:String, buildRoot:String,
			projectRoot:String, fallback:Void->Int):Int {
		if (Sys.getEnv("HAXEON_COMPILER_SERVER") == "0" || (Sys.systemName() != "Linux" && Sys.systemName() != "Mac"))
			return fallback();
		var connection:Null<Connection> = null;
		try {
			var directory = Path.join([buildRoot, ".haxeon", "compiler"]);
			FileSystem.createDirectory(directory);
			if (Sys.command("chmod", ["700", directory]) != 0)
				throw "Could not make the compiler session directory private";
			// Changes to the compiler, runtime sources, or launch environment select a new worker.
			var identity = new ExecutionAction(new ActionId("compiler-session-v5"), [],
				[compilerSource, Path.join([home, "stdlib"])], [], projectRoot,
				ExecutionAction.ActionKind.Process(command, [compilerSource], home, new Map())),
				key = ActionFingerprint.compute(identity, buildRoot, Sys.systemName(), []),
				statePath = Path.join([directory, key + ".json"]);
			connection = connect(statePath);
			if (connection == null) {
				var workerArtifact = Path.join([directory, key + ".hl"]),
					hashlink = Path.join([home, ".tools", "hashlink", "hl"]),
					logPath = Path.join([directory, key + ".log"]);
				if (!FileSystem.exists(workerArtifact)) {
					var compileStatus = ProcessRunner.run(command,
						["-cp", compilerSource, "-hl", workerArtifact, "-main", "compiler.tools.CompilerServer"], home, new Map());
					if (compileStatus != 0)
						throw "Could not compile the persistent compiler worker";
				}
				var libraryVariable = Sys.systemName() == "Mac" ? "DYLD_LIBRARY_PATH" : "LD_LIBRARY_PATH",
					libraryPath = [Path.join([home, "out"]), Path.join([home, ".tools", "hashlink"]), Sys.getEnv(libraryVariable)]
						.filter(value -> value != null && value.length > 0).join(":"),
					launch = [hashlink, workerArtifact, statePath].map(SysTools.quoteUnixArg).join(" ");
				// Redirect all three streams so the worker cannot keep the caller's
				// pipes open after the build exits.
				var detach = Sys.systemName() == "Linux" ? "setsid -f " : "",
					status = Sys.command("sh", ["-c", "umask 077; cd " + SysTools.quoteUnixArg(home)
					+ " && export " + libraryVariable + "=" + SysTools.quoteUnixArg(libraryPath)
					+ " && " + detach + "nohup " + launch + " > " + SysTools.quoteUnixArg(logPath) + " 2>&1 < /dev/null &"]);
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
			shutdownObsoleteWorkers(directory, statePath);
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
					return response.status;
				}
			}
		} catch (error:Dynamic) {
			if (connection != null)
				try connection.socket.close() catch (_:Dynamic) {}
			Sys.println("Compiler session unavailable; using one-shot compilation: " + Std.string(error));
			return fallback();
		}
	}

	static function connect(statePath:String):Null<Connection> {
		var socket:Null<Socket> = null;
		try {
			var state:Dynamic = Json.parse(File.getContent(statePath));
			if (!Std.isOfType(state.port, Int) || state.port <= 0 || state.port > 65535
				|| !Std.isOfType(state.token, String) || state.token.length != 64)
				return null;
			socket = new Socket();
			socket.setTimeout(0.2);
			socket.connect(new Host("127.0.0.1"), state.port);
			return {socket: socket, token: state.token};
		} catch (_:Dynamic) {
			if (socket != null)
				try socket.close() catch (_:Dynamic) {}
			return null;
		}
	}

	static function shutdownObsoleteWorkers(directory:String, currentStatePath:String):Void {
		for (entry in FileSystem.readDirectory(directory)) {
			if (!StringTools.endsWith(entry, ".json"))
				continue;
			var statePath = Path.join([directory, entry]);
			if (statePath == currentStatePath)
				continue;
			var connection = connect(statePath);
			if (connection == null)
				continue;
			try {
				var request = haxe.io.Bytes.ofString(Json.stringify({token: connection.token, shutdown: true}));
				connection.socket.output.writeInt32(request.length);
				connection.socket.output.write(request);
				connection.socket.output.flush();
				connection.socket.setTimeout(1);
				connection.socket.input.readLine();
				connection.socket.close();
			} catch (_:Dynamic) {
				try connection.socket.close() catch (_:Dynamic) {}
			}
		}
	}
}
