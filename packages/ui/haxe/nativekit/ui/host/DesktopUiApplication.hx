package nativekit.ui.host;

/** Compatibility name retained for existing desktop applications. */
interface DesktopUiApplication extends UiApplication {
	public function diagnosticState():Dynamic;
}
