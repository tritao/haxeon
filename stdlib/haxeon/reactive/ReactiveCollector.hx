package haxeon.reactive;

/** A tracked computation or build that records reactive sources it reads. */
interface ReactiveCollector {
	/** Records that the computation read `source`. */
	function track(source:ReactiveSource):Void;

	/** Records that the computation read the field `fieldBit` of `source`. */
	function trackField(source:ReactiveSource, fieldBit:Int):Void;
}
