package runtime.hashlink;

/** Borrowed view of one published metadata generation. */
class HlMetadataLease {
	public final publication:HlMetadataPublication;
	final generation:HlMetadataGeneration;
	var released:Bool = false;

	@:allow(runtime.hashlink.HlMetadataGeneration)
	function new(generation:HlMetadataGeneration) {
		this.generation = generation;
		publication = generation.snapshot();
		generation.retainBorrow();
	}

	/** Release this borrow. Repeated release is safe. */
	public function release():Void {
		if (released)
			return;
		released = true;
		generation.releaseBorrow();
	}

	public inline function isReleased():Bool
		return released;
}
