package runtime.hashlink;

/** Borrowed view of one published metadata generation. */
class HlMetadataLease {
	public final publication:HlMetadataPublication;
	final generation:HlMetadataGeneration;
	var released:Bool = false;

	@:allow(runtime.hashlink.HlMetadataGeneration)
	function new(generation:HlMetadataGeneration, publication:HlMetadataPublication) {
		this.generation = generation;
		this.publication = publication;
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
