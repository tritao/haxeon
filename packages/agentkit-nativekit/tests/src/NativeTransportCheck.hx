import haxeon.agent.nativekit.NativeKitHttpTransport;

/** Compile check only: a live run needs the native NativeKit library, see exosuit tests/agentkit-transport. */
class NativeTransportCheck {
	static function main():Void {
		var transport:Null<NativeKitHttpTransport> = null;
		Sys.println(transport == null ? "agentkit-nativekit compiles" : "unexpected");
	}
}
