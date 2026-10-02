import HostErrorProbe;
import haxeon.wasm.HostError;

// A call the host cannot provide throws haxeon.wasm.HostError into the guest, which a typed catch handles.
function main():Int {
	try {
		HostErrorProbe.missingCall(1);
		return 1;
	} catch (error:HostError) {
		return error.message.indexOf("missing_lib.missing_call") >= 0 ? 42 : 2;
	}
}
