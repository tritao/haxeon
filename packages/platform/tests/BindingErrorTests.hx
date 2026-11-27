import haxeon.platform.BindingError;
import haxeon.platform.BindingErrorKind;
import haxeon.platform.NativeKitError;
import haxeon.platform.NativeKitStatus;
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
		// An environment's answer is an error case: a network failure under Network, content under InvalidData.
		var answers = NativeKitStatus.error(Result.HttpDns, "test", null).match(Network(HostNotFound))
			&& NativeKitStatus.error(Result.TransportClosed, "test", null).match(Network(Closed))
			&& NativeKitStatus.error(Result.HttpTls, "test",
			"bad certificate").match(Network(TlsFailed("bad certificate")))
			&& NativeKitStatus.error(Result.HttpCanceled, "test", null).match(Cancelled)
			&& NativeKitStatus.error(Result.ErrorInvalidData, "test", "not audio").match(InvalidData("not audio"))
			&& NativeKitStatus.error(Result.HttpDns, "test", null).describe() == "host not found";
		var misuse = false;
		try _ = NativeKitStatus.error(Result.ErrorInvalidArgument, "test", null) catch (error:BindingError)
			misuse = error.kind == BindingErrorKind.InvalidArgument;
		return argument && malformed && base && backend && answers && misuse;
	}
}
