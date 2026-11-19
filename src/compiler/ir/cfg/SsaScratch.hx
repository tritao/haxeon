package compiler.ir.cfg;

/**
 * Working storage of `SsaBuilder` kept from one function to the next by its owner (`IrGenerator`), so building a program's SSA
 * allocates each array once, at the size of its largest function. One builder uses it at a time.
 */
class SsaScratch {
	/** Liveness, a row of words per block: live into the block, read before written in it, written in it. */
	public final live:Array<Int> = [];

	public final uses:Array<Int> = [];
	public final defs:Array<Int> = [];
	public final work:Array<Int> = [];
	public final queued:Array<Bool> = [];

	/** The slot of each local of the function being built (`SsaBuilder.slotFor`). */
	public final slots:Map<String, Int> = [];

	final valueNames:Array<String> = [];

	/** `v<id>`, the name of a CFG value's SSA value, made once per id. */
	public function valueName(id:Int):String {
		while (valueNames.length <= id)
			valueNames.push("v" + valueNames.length);
		return valueNames[id];
	}

	public function new() {}

	/** Sets `values` to `count` zeros, keeping its storage. */
	public static function zero(values:Array<Int>, count:Int):Void {
		values.resize(count);
		for (index in 0...count)
			values[index] = 0;
	}
}
