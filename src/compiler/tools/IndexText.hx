package compiler.tools;

/**
 * A text made from a map of names to numbers (a module's function indices or stable ids), kept while the map reads the same: a
 * session writes these side files after every build, and an edit seldom changes them.
 */
class IndexText {
	var last:Null<Map<String, Int>> = null;
	var lastCount = 0;
	var text = "";

	public function new() {}

	/** `make(indices)`, or the text made last when `indices` has the same entries as the map it was made from. */
	public function of(indices:Map<String, Int>, make:Map<String, Int>->String):String {
		var count = 0, same = last != null;
		for (name => index in indices) {
			count++;
			if (same && last.get(name) != index)
				same = false;
		}
		if (same && count == lastCount)
			return text;
		last = [for (name => index in indices) name => index];
		lastCount = count;
		text = make(indices);
		return text;
	}
}
