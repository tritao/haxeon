package haxeon.reactive;

/** An adaptive reader-local table. Hashes choose a bucket; identity decides equality. */
class ReactiveIdentityIndex {
	var sources:Array<Null<ReactiveSource>>;
	var bits:Array<Int>;
	var edges:Array<Null<ReactiveEdge>>;
	// Capture slices can become small again after a large one. Keep the occupied
	// slots so clearing a slice costs O(its reads), not O(the largest past slice).
	var occupied:Array<Int>;
	var count:Int = 0;

	public function new(captureOnly:Bool) {
		if (captureOnly) occupied = [];
		// Promotion happens after 1,024 entries. Start below half full without
		// allocating and discarding several smaller tables during promotion.
		allocate(4096);
	}

	function allocate(capacity:Int):Void {
		sources = []; sources.resize(capacity);
		bits = []; bits.resize(capacity);
		edges = []; edges.resize(capacity);
	}

	function slot(source:ReactiveSource, bit:Int):Int {
		var mask = sources.length - 1;
		var index = (source.identityHash ^ (bit * 0x9e3779b9)) & mask;
		while (sources[index] != null && (!haxeon.Identity.same(sources[index], source) || bits[index] != bit))
			index = (index + 1) & mask;
		return index;
	}

	public function contains(source:ReactiveSource, bit:Int):Bool return sources[slot(source, bit)] != null;
	public function get(source:ReactiveSource, bit:Int):Null<ReactiveEdge> return edges[slot(source, bit)];

	public function put(source:ReactiveSource, bit:Int, edge:Null<ReactiveEdge>):Void {
		if ((count + 1) * 2 > sources.length) grow();
		var index = slot(source, bit);
		if (sources[index] == null) {
			count++;
			if (occupied != null) occupied.push(index);
		}
		sources[index] = source; bits[index] = bit; edges[index] = edge;
	}

	function grow():Void {
		var oldSources = sources, oldBits = bits, oldEdges = edges;
		allocate(oldSources.length * 2); count = 0;
		if (occupied != null) occupied.resize(0);
		for (index in 0...oldSources.length)
			if (oldSources[index] != null) put(oldSources[index], oldBits[index], oldEdges[index]);
	}

	public function remove(source:ReactiveSource, bit:Int):Void {
		var index = slot(source, bit);
		if (sources[index] == null) return;
		var mask = sources.length - 1;
		sources[index] = null; edges[index] = null; count--;
		index = (index + 1) & mask;
		while (sources[index] != null) {
			var displacedSource = sources[index], displacedBit = bits[index], displacedEdge = edges[index];
			sources[index] = null; edges[index] = null; count--;
			put(displacedSource, displacedBit, displacedEdge);
			index = (index + 1) & mask;
		}
	}

	public function clear():Void {
		if (occupied != null) {
			for (index in occupied) { sources[index] = null; edges[index] = null; }
			occupied.resize(0);
		} else
			for (index in 0...sources.length) { sources[index] = null; edges[index] = null; }
		count = 0;
	}
}
