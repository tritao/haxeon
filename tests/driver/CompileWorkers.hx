package driver;

import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;
import sys.net.Host;
import sys.net.Socket;

/** What one compile request answered: the status a one-shot compile would have exited with, and the messages it reported. */
typedef CompileOutcome = {
	var status:Int;
	var output:String;
}

/**
 * A compile server (`compiler.tools.CompilerServer`) this driver started, reached as any client reaches one: through the
 * rendezvous file it publishes, a port and a token. It serves one request at a time.
 */
class CompileWorker {
	final process:Process;
	final rendezvous:String;

	/** How to reach the server, once it has published it (`ready`); null until then. */
	var port:Null<Int> = null;

	var token:Null<String> = null;

	/**
	 * Starts `command` with `rendezvous` appended, without waiting for it: a pool starts its servers together, and each request
	 * waits for its own (`ready`), so starting N servers costs one start, not N.
	 */
	public function new(command:Array<String>, rendezvous:String) {
		this.rendezvous = rendezvous;
		// The server answers through its socket and prints only when it fails, which is when its output is read (`printed`): no
		// thread waits on its pipes, as a thread blocked in a read would hold up every collection of this process.
		process = new Process(command[0], command.slice(1).concat([rendezvous]));
	}

	/** Waits until the server has published how to reach it, and returns its port. */
	function ready():Int {
		var known = port;
		if (known != null)
			return known;
		var deadline = Sys.time() + 300;
		while (!FileSystem.exists(rendezvous)) {
			if (process.exitCode(false) != null || Sys.time() > deadline)
				throw 'the compile server did not start: ${printed()}';
			Sys.sleep(0.02);
		}
		var state:Dynamic = Json.parse(File.getContent(rendezvous));
		token = state.token;
		port = state.port;
		return state.port;
	}

	/** Sends one compile request, whose answer `answer` reads. */
	public function send(arguments:Array<String>):Socket {
		var socket = new Socket();
		socket.connect(new Host("127.0.0.1"), ready());
		socket.setTimeout(3600);
		var bytes = haxe.io.Bytes.ofString(Json.stringify({token: token, arguments: arguments}));
		socket.output.writeInt32(bytes.length);
		socket.output.write(bytes);
		socket.output.flush();
		return socket;
	}

	/** The answer to the request `socket` sent: its messages, one per line, and its status. */
	public function answer(socket:Socket):CompileOutcome {
		var output = new StringBuf();
		try {
			while (true) {
				var response:Dynamic = Json.parse(socket.input.readLine());
				if (response.message != null)
					output.add(response.message + "\n");
				if (response.status != null) {
					socket.close();
					return {status: response.status, output: output.toString()};
				}
			}
		} catch (error:Dynamic) {
			socket.close();
			return {status: 1,
				output: output.toString() + 'the compile server stopped answering: $error\n${printed()}'};
		}
	}

	public function compile(arguments:Array<String>):CompileOutcome
		return answer(send(arguments));

	/** Whether the server is still running; one that stopped is not used again. */
	public function alive():Bool
		return process.exitCode(false) == null;

	public function shutdown():Void {
		if (alive() && port != null)
			try {
				var socket = new Socket();
				socket.connect(new Host("127.0.0.1"), port);
				var bytes = haxe.io.Bytes.ofString(Json.stringify({token: token, shutdown: true}));
				socket.output.writeInt32(bytes.length);
				socket.output.write(bytes);
				socket.output.flush();
				socket.close();
			} catch (_:Dynamic) {}
		process.exitCode();
		process.close();
	}

	/** What the server printed, once it has stopped; nothing while it runs, as reading its pipes then would wait for it. */
	function printed():String {
		if (process.exitCode(false) == null)
			return "";
		var text = "";
		for (stream in [process.stdout, process.stderr])
			try
				text += stream.readAll().toString()
			catch (_:Dynamic) {}
		return text;
	}

}

/**
 * The compile servers the program cases compile in: a program's compile does not start the VM or load the compiler, and each
 * asks for a fresh session (`--session=fresh`), so it owes nothing to the programs compiled before it. A server serves one
 * request at a time and returns to the pool when its answer has been read; one that stopped is not used again.
 */
class CompileWorkers {
	final command:Array<String>;
	final directory:String;
	final idle:Array<CompileWorker> = [];
	var started = 0;

	/** `command` starts a compile server once the rendezvous path is appended; rendezvous files go in `directory`. */
	public function new(command:Array<String>, directory:String) {
		this.command = command;
		this.directory = directory;
		FileSystem.createDirectory(directory);
	}

	/** Starts servers until `count` are idle, all at once, so the requests that follow do not wait for them one by one. */
	public function prestart(count:Int):Void
		while (idle.length < count)
			idle.push(new CompileWorker(command, Path.join([directory, 'compile-worker-${started++}.json'])));

	function acquire():CompileWorker {
		while (idle.length > 0) {
			var worker = idle.pop();
			if (worker.alive())
				return worker;
			worker.shutdown();
		}
		return new CompileWorker(command, Path.join([directory, 'compile-worker-${started++}.json']));
	}

	function release(worker:CompileWorker):Void
		if (worker.alive())
			idle.push(worker);
		else
			worker.shutdown();

	/** Sends one compile request now; `finish` waits for its answer. */
	public function start(arguments:Array<String>):{finish:Void->CompileOutcome} {
		var worker = acquire(), socket = worker.send(arguments);
		return {finish: () -> {
			var outcome = worker.answer(socket);
			release(worker);
			return outcome;
		}
		};
	}

	/**
	 * Sends one request to a server started for it alone and stopped after it answers: a compile that owes nothing to any compile
	 * before it in the same process. The server starts now and the request goes when `finish` is called, so its start overlaps
	 * whatever runs meanwhile.
	 */
	public function isolated(arguments:Array<String>):{finish:Void->CompileOutcome} {
		var worker = new CompileWorker(command, Path.join([directory, 'compile-worker-${started++}.json']));
		return {finish: () -> {
			var outcome = try worker.compile(arguments) catch (error:Dynamic) {
				status:1, output:'the isolated compile server failed: $error\n'
			};
			worker.shutdown();
			return outcome;
		}
		};
	}

	/** Runs `use` with a server of its own, for a sequence of requests that build on one session (a warm edit). */
	public function with<T>(use:CompileWorker->T):T {
		var worker = acquire();
		try {
			var result = use(worker);
			release(worker);
			return result;
		} catch (error:Dynamic) {
			release(worker);
			throw error;
		}
	}

	public function close():Void {
		for (worker in idle)
			worker.shutdown();
		idle.resize(0);
	}
}
