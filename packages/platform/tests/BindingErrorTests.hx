import haxeon.platform.BindingError;
import haxeon.platform.BindingErrorKind;
import haxeon.platform.PlatformError;
import haxeon.platform.event.EventBytes;
import haxeon.platform.interop.TransportInterop;
import nativekit.ffi.NativeKitTypes;

class BindingErrorTests {
	public static function run():Bool {
		var argument = false;
		try TransportInterop.options(0) catch (error:BindingError) {
			argument = error.kind == BindingErrorKind.InvalidArgument
				&& error.code == BindingErrorKind.InvalidArgument.rawValue
				&& error.domain == "haxeon-bindings" && error.operation == "TransportInterop.options"
				&& error.diagnostic != null;
		}
		var malformed = false;
		try EventBytes.readU32(haxe.io.Bytes.alloc(0), 0) catch (error:BindingError) {
			malformed = error.kind == BindingErrorKind.InvalidData && error.operation == "EventBytes.readU32";
		}
		// Managed failures and backend failures are both catchable through PlatformError.
		var base = false;
		try TransportInterop.options(0) catch (error:PlatformError) base = error.domain == "haxeon-bindings";
		// A NativeKit code that is the program's mistake (here a handle that is not one) is a BindingError too.
		var backend = false;
		try TransportInterop.receive(TransportHandle.invalid(), 8) catch (error:BindingError) {
			backend = error.kind == BindingErrorKind.Disposed && error.operation == "TransportInterop.receive"
				&& error.diagnostic != null && error.diagnostic.indexOf("NativeKit result -3") >= 0;
		}
		return argument && malformed && base && backend;
	}
}
