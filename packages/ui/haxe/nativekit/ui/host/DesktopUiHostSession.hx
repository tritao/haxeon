package nativekit.ui.host;

/** A desktop host that yields to its caller after each event pump iteration. */
class DesktopUiHostSession {
	final pump:Void->Bool;
	final shutdown:Void->Int;
	var closed = false;
	var result = 0;

	public function new(pump:Void->Bool, shutdown:Void->Int) {
		this.pump = pump;
		this.shutdown = shutdown;
	}

	/** Returns false after the application requests close or the host fails. */
	public function tick():Bool
		return !closed && pump();

	public function close():Int {
		if (!closed) {
			closed = true;
			result = shutdown();
		}
		return result;
	}
}
