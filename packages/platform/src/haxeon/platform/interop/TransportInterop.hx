package haxeon.platform.interop;

import haxe.Int64;
import haxe.io.Bytes;
import haxeon.platform.BindingError;
import haxeon.platform.NativeKitError;
import haxeon.platform.interop.TransportSendQueue;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes.OwnedListenerHandle;
import nativekit.ffi.NativeKitTypes.OwnedTransportHandle;
import nativekit.ffi.NativeKitTypes.Result;
import nativekit.ffi.NativeKitTypes.TransportFlags;
import nativekit.ffi.NativeKitTypes.TransportHandle;
import nativekit.ffi.NativeKitTypes.TransportKind;
import nativekit.ffi.NativeKitTypes.TransportOptions;

/** Small Haxe façade over NativeKit's asynchronous transports. */
class TransportInterop {
	/** nk_transport_receive uses this transport-specific status when drained. */
	static inline final RECEIVE_WOULD_BLOCK:Int = -205;

	public static function options(port:Int, ?host:String = "127.0.0.1"):TransportOptions {
		if (port <= 0 || port > 65535)
			throw BindingError.invalidArgument("TransportInterop.options", "NativeKit transport port is outside the valid range");
		if (host == null || host.length == 0)
			throw BindingError.invalidArgument("TransportInterop.options", "NativeKit transport host must not be empty");
		var value = new TransportOptions();
		value.set_struct_size(TransportOptions.size());
		value.set_kind(TransportKind.Tcp);
		value.set_flags(TransportFlags.NoDelay);
		value.set_host(host);
		value.set_port(port);
		value.set_timeout_ms(5000);
		value.set_backlog(8);
		value.set_receive_buffer_size(Int64.ofInt(4 * 1024 * 1024));
		value.set_send_buffer_size(Int64.ofInt(4 * 1024 * 1024));
		return value;
	}

	public static function listen(port:Int, ?host:String = "127.0.0.1"):OwnedListenerHandle {
		var value = options(port, host);
		value.set_flags(TransportFlags.ReuseAddress);
		var result = NativeKit.nk_transport_listen(value);
		if (result.status != Result.Ok)
			throw new NativeKitError(result.status, "TransportInterop.listen", NativeKit.nk_last_error());
		return result.out_listener;
	}

	public static function connect(host:String, port:Int):OwnedTransportHandle {
		var value = options(port, host);
		var result = NativeKit.nk_transport_connect(value);
		if (result.status != Result.Ok)
			throw new NativeKitError(result.status, "TransportInterop.connect", NativeKit.nk_last_error());
		return result.out_transport;
	}

	/** WebSocket JSON/message transport; NativeKit owns the handshake and control frames. */
	public static function websocket(host:String, port:Int, path:String, timeout:Float, secure:Bool = false):OwnedTransportHandle {
		if (!Math.isFinite(timeout) || timeout < 0.001 || timeout > 2147483.0)
			throw BindingError.invalidArgument("TransportInterop.websocket", "Invalid WebSocket timeout");
		var value = options(port, host);
		value.set_kind(TransportKind.Websocket);
		value.set_flags(TransportFlags.Messages | TransportFlags.Text | (secure ? TransportFlags.Secure : 0));
		value.set_path(path);
		value.set_timeout_ms(Std.int(timeout * 1000));
		var result = NativeKit.nk_transport_connect(value);
		if (result.status != Result.Ok)
			throw new NativeKitError(result.status, "TransportInterop.websocket", NativeKit.nk_last_error());
		return result.out_transport;
	}

	/** Null means drained; an empty Bytes value is a complete empty message. */
	public static function receiveMessage(transport:TransportHandle):Null<Bytes> {
		var buffer = Bytes.alloc(65536);
		var result = NativeKit.nk_transport_receive(transport, buffer);
		if (result.status == RECEIVE_WOULD_BLOCK)
			return null;
		if (result.status == Result.ErrorPayloadTooLarge) {
			var needed = Int64.toInt(result.out_received);
			if (needed < 0 || needed > 4 * 1024 * 1024)
				throw new NativeKitError(result.status, "TransportInterop.receiveMessage", "NativeKit message exceeds receive limit");
			buffer = Bytes.alloc(needed);
			result = NativeKit.nk_transport_receive(transport, buffer);
		}
		if (result.status != Result.Ok)
			throw new NativeKitError(result.status, "TransportInterop.receiveMessage", NativeKit.nk_last_error());
		return Bytes.view(buffer, 0, Int64.toInt(result.out_received));
	}

	public static function send(transport:TransportHandle, bytes:Bytes):Void {
		if (bytes == null)
			throw BindingError.invalidArgument("TransportInterop.send", "NativeKit transport cannot send null bytes");
		NativeKit.nk_transport_send_checked(transport, bytes);
	}

	public static function sendStatus(transport:TransportHandle, bytes:Bytes):Int {
		if (bytes == null)
			throw BindingError.invalidArgument("TransportInterop.sendStatus", "NativeKit transport cannot send null bytes");
		return NativeKit.nk_transport_send(transport, bytes);
	}

	public static function sendQueue(transport:TransportHandle):TransportSendQueue {
		var result = NativeKit.nk_transport_get_send_queue(transport);
		if (result.status != Result.Ok)
			throw new NativeKitError(result.status, "TransportInterop.sendQueue", NativeKit.nk_last_error());
		return new TransportSendQueue(result.out_queued_bytes, result.out_capacity);
	}

	/**
		The process at the other end of a local transport, as the OS reports it (0 when unknown or not
		local). On Windows a connected client has already checked that the server runs as this user.
	**/
	public static function peerProcess(transport:TransportHandle):Int {
		var result = NativeKit.nk_transport_get_peer_process(transport);
		return result.status == Result.Ok ? Int64.toInt(result.out_process_id) : 0;
	}

	public static function receive(transport:TransportHandle, ?capacity:Int = 64 * 1024):Bytes {
		if (capacity <= 0)
			throw BindingError.invalidArgument("TransportInterop.receive", "NativeKit transport receive capacity must be positive");
		var buffer = Bytes.alloc(capacity);
		var result = NativeKit.nk_transport_receive(transport, buffer);
		if (result.status == RECEIVE_WOULD_BLOCK)
			return Bytes.alloc(0);
		if (result.status != Result.Ok)
			throw new NativeKitError(result.status, "TransportInterop.receive", NativeKit.nk_last_error());
		var count = Int64.toInt(result.out_received);
		return count == 0 ? Bytes.alloc(0) : Bytes.view(buffer, 0, count);
	}

	public static function close(transport:TransportHandle):Void
		NativeKit.nk_transport_close_checked(transport);
}
