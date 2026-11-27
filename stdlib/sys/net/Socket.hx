package sys.net;

import haxe.io.Bytes;
import haxe.io.Eof;
import haxe.io.Error;

#if !wasm
private typedef SocketHandle = hl.Abstract<"hl_socket">;

@:hlNative("haxeon_runtime", "__socket_new")
internal extern function socketNew(udp:Bool):Null<SocketHandle>;

@:hlNative("haxeon_runtime", "__socket_close")
internal extern function socketClose(s:SocketHandle):Void;

@:hlNative("haxeon_runtime", "__socket_send_byte")
internal extern function socketSendByte(s:SocketHandle, c:Int):Int;

@:hlNative("haxeon_runtime", "__socket_recv_byte")
internal extern function socketRecvByte(s:SocketHandle):Int;

@:hlNative("haxeon_runtime", "__socket_send")
internal extern function socketSend(s:SocketHandle, bytes:Bytes, pos:Int, len:Int):Int;

@:hlNative("haxeon_runtime", "__socket_recv")
internal extern function socketRecv(s:SocketHandle, bytes:Bytes, pos:Int, len:Int):Int;

@:hlNative("haxeon_runtime", "__socket_connect")
internal extern function socketConnect(s:SocketHandle, host:Int, port:Int):Bool;

@:hlNative("haxeon_runtime", "__socket_listen")
internal extern function socketListen(s:SocketHandle, n:Int):Bool;

@:hlNative("haxeon_runtime", "__socket_bind")
internal extern function socketBind(s:SocketHandle, host:Int, port:Int):Bool;

@:hlNative("haxeon_runtime", "__socket_accept")
internal extern function socketAccept(s:SocketHandle):Null<SocketHandle>;

@:hlNative("haxeon_runtime", "__socket_set_timeout")
internal extern function socketSetTimeout(s:SocketHandle, timeout:Float):Bool;

@:hlNative("haxeon_runtime", "__socket_shutdown")
internal extern function socketShutdown(s:SocketHandle, read:Bool, write:Bool):Bool;

@:hlNative("haxeon_runtime", "__socket_set_blocking")
internal extern function socketSetBlocking(s:SocketHandle, blocking:Bool):Bool;

@:hlNative("haxeon_runtime", "__socket_select")
internal extern function socketSelect(read:Array<Null<SocketHandle>>, write:Array<Null<SocketHandle>>,
		others:Array<Null<SocketHandle>>,
		timeout:Float):Bool;

@:hlNative("haxeon_runtime", "__socket_set_fast_send")
internal extern function socketSetFastSend(s:SocketHandle, fast:Bool):Bool;

@:hlNative("haxeon_runtime", "__socket_host_ip")
internal extern function socketHostIp(s:SocketHandle):Int;

@:hlNative("haxeon_runtime", "__socket_host_port")
internal extern function socketHostPort(s:SocketHandle):Int;

@:hlNative("haxeon_runtime", "__socket_peer_ip")
internal extern function socketPeerIp(s:SocketHandle):Int;

@:hlNative("haxeon_runtime", "__socket_peer_port")
internal extern function socketPeerPort(s:SocketHandle):Int;

/** What a socket receives. A closed connection is the end of the input. */
private class SocketInput extends haxe.io.Input {
	final handle:SocketHandle;

	public function new(handle:SocketHandle)
		this.handle = handle;

	override public function readByte():Int {
		var c = socketRecvByte(handle);
		if (c < 0) {
			if (c == -1)
				throw Error.Blocked;
			throw new Eof();
		}
		return c;
	}

	override public function readBytes(s:Bytes, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > s.length)
			throw Error.OutsideBounds;
		if (len == 0)
			return 0;
		var count = socketRecv(handle, s, pos, len);
		if (count <= 0) {
			if (count == -1)
				throw Error.Blocked;
			throw new Eof();
		}
		return count;
	}
}

/** What a socket sends. */
private class SocketOutput extends haxe.io.Output {
	final handle:SocketHandle;

	public function new(handle:SocketHandle)
		this.handle = handle;

	override public function writeByte(c:Int):Void {
		var sent = socketSendByte(handle, c);
		if (sent < 0) {
			if (sent == -1)
				throw Error.Blocked;
			throw new Eof();
		}
	}

	override public function writeBytes(s:Bytes, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > s.length)
			throw Error.OutsideBounds;
		var sent = socketSend(handle, s, pos, len);
		if (sent < 0) {
			if (sent == -1)
				throw Error.Blocked;
			throw new Eof();
		}
		return sent;
	}
}
#end

/** A TCP socket, as in Haxe's sys.net.Socket (without `waitForRead`). */
class Socket {
	#if !wasm
	final handle:SocketHandle;
	#end

	/**
	 * What the peer sends, to read. Reading blocks unless the socket is not blocking, when it throws
	 * `haxe.io.Error.Blocked`.
	 */
	public var input(default, null):haxe.io.Input;

	/** What to send the peer, to write. */
	public var output(default, null):haxe.io.Output;

	/** Free for the program's own use. */
	public var custom:Dynamic;

	/**
	 * A new TCP socket, as Haxe's `new Socket()`. `accepted` is internal to this module, for `accept` to wrap the connection it
	 * takes: its type is private, so other code can only leave it out.
	 */
	public function new(#if !wasm ?accepted:SocketHandle #end) {
		#if wasm
		throw "Sockets are not available on Wasm";
		#else
		var created = accepted != null ? accepted : socketNew(false);
		if (created == null)
			throw "Socket creation failed";
		handle = created;
		input = new SocketInput(handle);
		output = new SocketOutput(handle);
		#end
	}

	/** Closes the socket, and its connection. */
	public function close():Void {
		#if !wasm
		socketClose(handle);
		#end
	}

	/** Everything the peer sends until it closes, as a String. */
	public function read():String
		return input.readAll().toString();

	/** Sends `content`, in UTF-8. */
	public function write(content:String):Void
		output.writeString(content);

	/** Connects to `port` of `host`. Throws when it cannot. */
	public function connect(host:Host, port:Int):Void {
		#if !wasm
		if (!socketConnect(handle, host.ip, port))
			throw 'Failed to connect on ${host.toString()}:$port';
		#end
	}

	/**
	 * Makes a bound socket accept connections, with up to `connections` waiting to be accepted. Throws when it cannot.
	 */
	public function listen(connections:Int):Void {
		#if !wasm
		if (!socketListen(handle, connections))
			throw "listen() failure";
		#end
	}

	/**
	 * Ends the reading side, the writing side, or both, of the connection, which stays open until `close`. Throws when
	 * it cannot.
	 */
	public function shutdown(read:Bool, write:Bool):Void {
		#if !wasm
		if (!socketShutdown(handle, read, write))
			throw "shutdown() failure";
		#end
	}

	/** Binds the socket to `port` of the local address `host`, to `listen` on. Throws when it cannot. */
	public function bind(host:Host, port:Int):Void {
		#if !wasm
		if (!socketBind(handle, host.ip, port))
			throw 'Cannot bind socket on ${host.toString()}:$port';
		#end
	}

	/** Waits for a connection to the listening socket and returns a socket for it. Throws when it cannot. */
	public function accept():Socket {
		#if wasm
		throw "Sockets are not available on Wasm";
		#else
		var accepted = socketAccept(handle);
		if (accepted == null)
			throw "accept() failure";
		return new Socket(accepted);
		#end
	}

	/** The address and port of the other end of the connection. */
	public function peer():{host:Host, port:Int} {
		#if wasm
		throw "Sockets are not available on Wasm";
		#else
		return {host: Host.ofIp(socketPeerIp(handle)), port: socketPeerPort(handle)};
		#end
	}

	/** The local address and port the socket is bound to. */
	public function host():{host:Host, port:Int} {
		#if wasm
		throw "Sockets are not available on Wasm";
		#else
		return {host: Host.ofIp(socketHostIp(handle)), port: socketHostPort(handle)};
		#end
	}

	/** Makes reads and writes fail after waiting `timeout` seconds. Throws when it cannot. */
	public function setTimeout(timeout:Float):Void {
		#if !wasm
		if (!socketSetTimeout(handle, timeout))
			throw "setTimeout() failure";
		#end
	}

	/**
	 * Whether reads, writes, `connect` and `accept` wait; without, one that would wait throws `haxe.io.Error.Blocked`.
	 * Throws when it cannot.
	 */
	public function setBlocking(blocking:Bool):Void {
		#if !wasm
		if (!socketSetBlocking(handle, blocking))
			throw "setBlocking() failure";
		#end
	}

	/**
	 * The sockets of each list that are ready to read, to write, or have an exceptional condition, as Haxe's: waits up to
	 * `timeout` seconds, or until one is ready without a timeout.
	 */
	public static function select(read:Array<Socket>, write:Array<Socket>, others:Array<Socket>,
			?timeout:Float):{
				read:Array<Socket>,
				write:Array<Socket>,
				others:Array<Socket>
			} {
		#if wasm
		throw "Sockets are not available on Wasm";
		#else
		var readHandles = handlesOf(read), writeHandles = handlesOf(write), otherHandles = handlesOf(others);
		if (!socketSelect(readHandles, writeHandles, otherHandles, timeout == null ? -1.0 : timeout))
			throw "select() failure";
		return {read: ready(read, readHandles), write: ready(write, writeHandles), others: ready(others, otherHandles)};
		#end
	}

	#if !wasm
	static function handlesOf(sockets:Null<Array<Socket>>):Array<Null<SocketHandle>> {
		var handles:Array<Null<SocketHandle>> = [];
		if (sockets != null)
			for (socket in sockets)
				handles.push(socket.handle);
		return handles;
	}

	/** The sockets whose handles select kept, in the order it left them (ready ones first, then a null). */
	static function ready(sockets:Null<Array<Socket>>, handles:Array<Null<SocketHandle>>):Array<Socket> {
		var result:Array<Socket> = [];
		if (sockets == null)
			return result;
		for (handle in handles) {
			if (handle == null)
				break;
			for (socket in sockets)
				if (socket.handle == handle) {
					result.push(socket);
					break;
				}
		}
		return result;
	}
	#end

	/** Whether small writes are sent at once, without waiting to join them (TCP_NODELAY). Throws when it cannot. */
	public function setFastSend(fast:Bool):Void {
		#if !wasm
		if (!socketSetFastSend(handle, fast))
			throw "setFastSend() failure";
		#end
	}
}
