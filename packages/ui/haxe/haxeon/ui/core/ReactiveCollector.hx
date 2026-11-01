package haxeon.ui.core;

/** A tracked computation or build that records reactive sources it reads. */
interface ReactiveCollector {
	function track(source:ReactiveSource):Void;
}
