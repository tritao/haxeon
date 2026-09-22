package compiler.tools;

import compiler.Diagnostic.CompileError;
import haxe.Json;
import sys.io.File;
import sys.FileSystem;
import sys.net.Host;
import sys.net.Socket;

/** Private loopback worker for one project's build session. Exits after five idle minutes. */
class CompilerServer {
	public static function main():Void {
		var args = Sys.args();
		if (args.length != 1)
			throw "CompilerServer requires a rendezvous path";
		serve(args[0]);
	}

	static function serve(statePath:String):Void {
		var random = File.read("/dev/urandom", true), token = random.read(32).toHex();
		random.close();
		var listener = new Socket(), session = new CompilerSession(true);
		listener.bind(new Host("127.0.0.1"), 0);
		listener.listen(8);
		var descriptor = Json.stringify({port: listener.host().port, token: token});
		File.saveContent(statePath + "." + token + ".tmp", descriptor);
		FileSystem.rename(statePath + "." + token + ".tmp", statePath);
		try {
			var running = true;
			while (running) {
				if (Socket.select([listener], [], [], 300).read.length == 0)
					break;
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
						var result = CompilerDriver.compile(CompilerArguments.parse(cast request.arguments),
							message -> send(client, {message: message}), session);
						send(client, {message: 'compiler: ${Math.round((Sys.time() - started) * 1000)} ms, ${result.metrics.retypedFunctions} functions retyped'});
					}
					send(client, {status: 0});
				} catch (error:Dynamic) {
					session.reset();
					try {
						var message = Std.string(error);
						if (Std.isOfType(error, CompileError)) {
							var failure:CompileError = cast error, diagnostic = failure.diagnostic;
							message = diagnostic.span.file.path + ":" + diagnostic.span.start + ": " + diagnostic.code + ": " + diagnostic.message;
						}
						send(client, {message: message});
						send(client, {status: 1});
					} catch (_:Dynamic) {}
				}
				client.close();
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

	static function send(client:Socket, value:Dynamic):Void {
		client.output.writeString(Json.stringify(value) + "\n");
		client.output.flush();
	}
}
