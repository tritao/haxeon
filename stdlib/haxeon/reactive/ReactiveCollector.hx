package haxeon.reactive;

/** A tracked computation or build that records reactive sources it reads. */
interface ReactiveCollector {
	function track(source:ReactiveSource):Void;
	function trackField(source:ReactiveSource, fieldBit:Int):Void;
}
