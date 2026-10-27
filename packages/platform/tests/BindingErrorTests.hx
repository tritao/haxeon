import haxeon.platform.PlatformError;
import haxeon.platform.internal.event.EventBytes;
import haxeon.platform.interop.TransportInterop;
import haxeon.platform.BindingError;
import haxeon.platform.BindingErrorKind;
import haxeon.platform.NativeKitError;
import nativekit.ffi.NativeKitTypes;

class BindingErrorTests {
	public static function run():Bool {
		var argument = false;
		try TransportInterop.options(0) catch (error:BindingError) {
			argument = error.kind == BindingErrorKind.InvalidArgument && error.code == BindingErrorKind.InvalidArgument
				&& error.domain == "haxeon-bindings" && error.operation == "TransportInterop.options" && error.diagnostic != null;
		}
		var malformed = false;
		try EventBytes.readU32(haxe.io.Bytes.alloc(0), 0) catch (error:BindingError) {
			malformed = error.kind == BindingErrorKind.InvalidData && error.operation == "EventBytes.readU32";
		}
		// Managed failures and backend failures are both catchable through PlatformError.
		var base = false;
		try TransportInterop.options(0) catch (error:PlatformError) base = error.domain == "haxeon-bindings";
		var backend = false;
		try TransportInterop.receive(TransportHandle.invalid(), 8) catch (error:NativeKitError) {
			backend = error.domain == "nativekit" && error.result == Result.ErrorInvalidHandle && error.operation == "TransportInterop.receive";
		}
		return argument && malformed && base && backend;
	}
}
