package nativekit.ui.host;

/** Optional diagnostic state exposed by applications that support capture runs. */
interface UiDiagnosticsProvider {
	public function diagnosticState():Dynamic;
}
