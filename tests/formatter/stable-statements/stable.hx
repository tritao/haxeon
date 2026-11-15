class A {
	public static function setDiagnosticsEnabled(enabled:Bool):Void
		AudioResult.check(NativeKitAudio.nk_audio_set_diagnostics_enabled(enabled), "audio.diagnostics.enable");

	function f() {
		try
			IrVerifier.verify(ir)
		catch (error:String)
			throw 'failed: $error';
		try group.run() catch (error:Dynamic) {
			report(error);
		}
		for (index in 0...count)
			if (state.strings[index] != null)
				result.set(state.strings[index], index);
			else
				result.stringIndices.set(state.strings[index], index);
		var xs = [
			for (argument in arguments)
				canonicalType(argument)
		];
		switch op {
			case ValueInit(out)
				if (Type.enumEq(out.type, Obj("NestedCensus"))):
				x();
			default:
		}
	}
}
