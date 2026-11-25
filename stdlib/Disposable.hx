/** A resource that can be released deterministically. */
interface Disposable {
	/** Releases what the resource holds. Afterwards the value must not be used. */
	function dispose():Void;
}
