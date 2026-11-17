package compiler.tools;

import haxe.Json;
import haxe.io.Bytes;
import haxe.io.Input;
import haxe.io.Output;

/**
 * How a client reaches a compile server: the rendezvous file the server publishes once it listens, replaced atomically and
 * removed when it exits.
 */
typedef CompilerServerState = {
	final port:Int;

	/** 32 random bytes as hex; every request must carry it. */
	final token:String;

	/** The server's process, so a client can measure it and tell when it is gone; null where the runtime cannot say. */
	final pid:Null<Int>;

	/**
	 * Seconds without a request after which the server exits. It also tells a client how often to ping, and that the server
	 * understands pings: it is 0 in the state of a server from before pings.
	 */
	final idleSeconds:Float;
}

/** One request to a compile server. Each is sent on a connection of its own. */
enum CompilerServerRequest {
	/** Compiles with the compiler's own arguments (`CompilerArguments`); the answer is messages, then a status. */
	Compile(arguments:Array<String>);

	/**
	 * Compiles with nobody waiting: the server answers with a status at once and compiles after. A live run sends this to warm
	 * the session from a module it built before; later requests queue behind it.
	 */
	Background(arguments:Array<String>);

	/** Counts as activity, so the server does not idle out. It is not answered. */
	Ping;

	/** Stops the server once the connection closes; answered with a status. */
	Shutdown;
}

/** One line of a compile server's answer: any number of messages, then one status, after which the server closes. */
enum CompilerServerResponse {
	Message(text:String);

	/** The status a one-shot compile would have exited with. */
	Status(code:Int);
}

/**
 * The wire format of `CompilerServer`, shared by every client (`build.execution.CompilerClient`, the test driver's compile
 * workers) so a change to it is checked on both sides. A request is a 32-bit length and that many bytes of JSON carrying the
 * token; each response is a line of JSON.
 */
class CompilerServerProtocol {
	/** The largest request a server reads. */
	public static inline final MAX_REQUEST_BYTES = 8 * 1024 * 1024;

	public static function encodeState(state:CompilerServerState):String
		return Json.stringify({
			port: state.port,
			token: state.token,
			pid: state.pid,
			idleSeconds: state.idleSeconds
		});

	/** The state a rendezvous file holds, or null when it does not describe a server a client can reach. */
	public static function decodeState(text:String):Null<CompilerServerState> {
		var value:Dynamic = try Json.parse(text) catch (_:Dynamic) null;
		if (value == null || !Std.isOfType(value.port, Int) || !Std.isOfType(value.token, String))
			return null;
		var port:Int = value.port, token:String = value.token;
		if (port <= 0 || port > 65535 || token.length != 64)
			return null;
		var pid:Null<Int> = Std.isOfType(value.pid, Int) ? value.pid : null,
			idleSeconds:Float = Std.isOfType(value.idleSeconds, Float) ? value.idleSeconds : 0;
		return {
			port: port,
			token: token,
			pid: pid,
			idleSeconds: idleSeconds
		};
	}

	public static function writeRequest(output:Output, token:String, request:CompilerServerRequest):Void {
		var bytes = Bytes.ofString(Json.stringify(switch request {
			case Compile(arguments): {token: token, arguments: arguments};
			case Background(arguments): {token: token, arguments: arguments, background: true};
			case Ping: {token: token, ping: true};
			case Shutdown: {token: token, shutdown: true};
		}));
		output.writeInt32(bytes.length);
		output.write(bytes);
		output.flush();
	}

	/** Reads one request; throws when it is malformed or does not carry `token`. */
	public static function readRequest(input:Input, token:String):CompilerServerRequest {
		var length = input.readInt32();
		if (length <= 0 || length > MAX_REQUEST_BYTES)
			throw "Invalid compiler request length";
		var value:Dynamic = Json.parse(input.readString(length));
		if (value.token != token)
			throw "Invalid compiler session token";
		if (value.shutdown == true)
			return Shutdown;
		if (value.ping == true)
			return Ping;
		var items:Null<Array<Dynamic>> = value.arguments;
		if (items == null)
			throw "Invalid compiler request: no arguments";
		var arguments:Array<String> = [];
		for (item in items) {
			if (!Std.isOfType(item, String))
				throw "Invalid compiler request: an argument is not a string";
			arguments.push(item);
		}
		return value.background == true ? Background(arguments) : Compile(arguments);
	}

	public static function writeResponse(output:Output, response:CompilerServerResponse):Void {
		output.writeString(Json.stringify(switch response {
			case Message(text): {message: text};
			case Status(code): {status: code};
		}) + "\n");
		output.flush();
	}

	/** Reads one response line; throws when the line is neither a message nor a status. */
	public static function readResponse(input:Input):CompilerServerResponse {
		var value:Dynamic = Json.parse(input.readLine());
		if (value.status != null)
			return Status(value.status);
		if (value.message != null)
			return Message(Std.string(value.message));
		throw "Invalid compiler response";
	}
}
