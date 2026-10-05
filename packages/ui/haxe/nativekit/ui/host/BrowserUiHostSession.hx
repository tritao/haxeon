package nativekit.ui.host;

/** Browser session advanced by the embedding page's requestAnimationFrame callback. */
class BrowserUiHostSession extends UiHostSession {
	var owner:Null<BrowserUiHost> = null;

	@:allow(nativekit.ui.host.BrowserUiHost)
	function new() super(function() {
		if (owner != null) owner.stopHost();
	});

	@:allow(nativekit.ui.host.BrowserUiHost)
	function attach(owner:BrowserUiHost):Void this.owner = owner;

	/** Returns 1 while another browser frame is wanted, 0 when stopped, or -1 on failure. */
	public function advance(timeMilliseconds:Float):Int {
		return owner == null ? 0 : owner.advance(timeMilliseconds);
	}
}
