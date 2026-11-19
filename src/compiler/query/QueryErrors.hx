package compiler.query;

/** A query read itself, directly or through others: `path` is the queries on the cycle, the first read again last. */
class QueryCycle extends haxe.Exception {
	public final path:Array<String>;

	public function new(path:Array<String>) {
		super("query cycle: " + path.join(" -> "));
		this.path = path;
	}
}

/** Check mode found a reused query whose value differs from computing it again: it read something it did not record. */
class QueryReuseMismatch extends haxe.Exception {
	public final query:String;

	public function new(query:String) {
		super("reused query " + query + " differs from computing it again: it depends on a read it did not record");
		this.query = query;
	}
}
