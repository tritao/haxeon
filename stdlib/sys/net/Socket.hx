package sys.net;

import haxe.io.Bytes;
import haxe.io.Eof;
import haxe.io.Error;

#if !wasm
private typedef SocketHandle = hl.Abstract<"hl_socket">;

@:hlNative("haxeon_runtime", "__socket_new")
extern function socketNew(udp:Bool):Null<SocketHandle>;

@:hlNative("haxeon_runtime", "__socket_close")
extern function socketClose(s:SocketHandle):Void;

@:hlNative("haxeon_runtime", "__socket_send_byte")
extern function socketSendByte(s:SocketHandle, c:Int):Int;

@:hlNative("haxeon_runtime", "__socket_recv_byte")
extern function socketRecvByte(s:SocketHandle):Int;

@:hlNative("haxeon_runtime", "__socket_send")
extern function socketSend(s:SocketHandle, bytes:Bytes, pos:Int, len:Int):Int;

@:hlNative("haxeon_runtime", "__socket_recv")
extern function socketRecv(s:SocketHandle, bytes:Bytes, pos:Int, len:Int):Int;

@:hlNative("haxeon_runtime", "__socket_connect")
extern function socketConnect(s:SocketHandle, host:Int, port:Int):Bool;

@:hlNative("haxeon_runtime", "__socket_listen")
extern function socketListen(s:SocketHandle, n:Int):Bool;

@:hlNative("haxeon_runtime", "__socket_bind")
extern function socketBind(s:SocketHandle, host:Int, port:Int):Bool;

@:hlNative("haxeon_runtime", "__socket_accept")
extern function socketAccept(s:SocketHandle):Null<SocketHandle>;

@:hlNative("haxeon_runtime", "__socket_set_timeout")
extern function socketSetTimeout(s:SocketHandle, timeout:Float):Bool;

@:hlNative("haxeon_runtime", "__socket_shutdown")
extern function socketShutdown(s:SocketHandle, read:Bool, write:Bool):Bool;

@:hlNative("haxeon_runtime", "__socket_set_blocking")
extern function socketSetBlocking(s:SocketHandle, blocking:Bool):Bool;

@:hlNative("haxeon_runtime", "__socket_set_fast_send")
extern function socketSetFastSend(s:SocketHandle, fast:Bool):Bool;

@:hlNative("haxeon_runtime", "__socket_host_ip")
extern function socketHostIp(s:SocketHandle):Int;

@:hlNative("haxeon_runtime", "__socket_host_port")
extern function socketHostPort(s:SocketHandle):Int;

@:hlNative("haxeon_runtime", "__socket_peer_ip")
extern function socketPeerIp(s:SocketHandle):Int;

@:hlNative("haxeon_runtime", "__socket_peer_port")
extern function socketPeerPort(s:SocketHandle):Int;

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

/** A TCP socket, as in Haxe's sys.net.Socket (without `select` and `waitForRead`). */
class Socket {
	#if !wasm
	final handle:SocketHandle;
	#end

	public var input(default, null):haxe.io.Input;
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

	public function close():Void {
		#if !wasm
		socketClose(handle);
		#end
	}

	/** Everything the peer sends until it closes, as a String. */
	public function read():String
		return input.readAll().toString();

	public function write(content:String):Void
		output.writeString(content);

	public function connect(host:Host, port:Int):Void {
		#if !wasm
		if (!socketConnect(handle, host.ip, port))
			throw 'Failed to connect on ${host.toString()}:$port';
		#end
	}

	public function listen(connections:Int):Void {
		#if !wasm
		if (!socketListen(handle, connections))
			throw "listen() failure";
		#end
	}

	public function shutdown(read:Bool, write:Bool):Void {
		#if !wasm
		if (!socketShutdown(handle, read, write))
			throw "shutdown() failure";
		#end
	}

	public function bind(host:Host, port:Int):Void {
		#if !wasm
		if (!socketBind(handle, host.ip, port))
			throw 'Cannot bind socket on ${host.toString()}:$port';
		#end
	}

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

	public function peer(): {host: Host, port: Int} {
		#if wasm
		throw "Sockets are not available on Wasm";
		#else
		return {host: Host.ofIp(socketPeerIp(handle)), port: socketPeerPort(handle)};
		#end
	}

	public function host(): {host: Host, port: Int} {
		#if wasm
		throw "Sockets are not available on Wasm";
		#else
		return {host: Host.ofIp(socketHostIp(handle)), port: socketHostPort(handle)};
		#end
	}

	public function setTimeout(timeout:Float):Void {
		#if !wasm
		if (!socketSetTimeout(handle, timeout))
			throw "setTimeout() failure";
		#end
	}

	public function setBlocking(blocking:Bool):Void {
		#if !wasm
		if (!socketSetBlocking(handle, blocking))
			throw "setBlocking() failure";
		#end
	}

	public function setFastSend(fast:Bool):Void {
		#if !wasm
		if (!socketSetFastSend(handle, fast))
			throw "setFastSend() failure";
		#end
	}
}
