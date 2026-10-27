import haxeon.platform.BindingError;
import haxeon.platform.BindingErrorKind;
import haxeon.platform.NativeError;
import haxeon.platform.NativeKitError;
import haxeon.platform.NativeKitEventBytes;
import haxeon.platform.NativeTransport;
import nativekit.ffi.NativeKitTypes;

class BindingErrorTests {
	public static function run():Bool {
		var argument = false;
		try NativeTransport.options(0) catch (error:BindingError) {
			argument = error.kind == BindingErrorKind.InvalidArgument && error.code == BindingErrorKind.InvalidArgument
				&& error.domain == "haxeon-bindings" && error.operation == "NativeTransport.options" && error.diagnostic != null;
		}
		var malformed = false;
		try NativeKitEventBytes.readU32(haxe.io.Bytes.alloc(0), 0) catch (error:BindingError) {
			malformed = error.kind == BindingErrorKind.InvalidData && error.operation == "NativeKitEventBytes.readU32";
		}
		// Managed failures and backend failures are both catchable through NativeError.
		var base = false;
		try NativeTransport.options(0) catch (error:NativeError) base = error.domain == "haxeon-bindings";
		var backend = false;
		try NativeTransport.receive(TransportHandle.invalid(), 8) catch (error:NativeKitError) {
			backend = error.domain == "nativekit" && error.result == Result.ErrorInvalidHandle && error.operation == "NativeTransport.receive";
		}
		return argument && malformed && base && backend;
	}
}
