package runtime;

/** Lifecycle owned by a reload domain. */
interface Plugin {
	function activate():Void;
	function deactivate():Void;
}
