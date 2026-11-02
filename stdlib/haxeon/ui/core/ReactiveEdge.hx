package haxeon.ui.core;

/** One reusable source-to-reader dependency link. */
class ReactiveEdge {
	public final source:ReactiveSource;
	public final reader:ReactiveDependencySet;
	public final fieldBit:Int;
	public var stamp:Int = 0;
	public var seenVersion:Int = 0;
	public var sourcePrevious:ReactiveEdge;
	public var sourceNext:ReactiveEdge;
	public var readerPrevious:ReactiveEdge;
	public var readerNext:ReactiveEdge;

	public function new(source:ReactiveSource, reader:ReactiveDependencySet, fieldBit:Int) {
		this.source = source;
		this.reader = reader;
		this.fieldBit = fieldBit;
	}
}
