package compiler.hl.lower;

import compiler.ir.analysis.IrLoopBounds;
import compiler.ir.model.Ir.IrValue;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrValueId;

/**
 * What both HashLink backends know of the array bounds in the block being lowered: the array and index pairs a check proved
 * in range since the last row that may shrink an array (`HlLoweringDecisions.keepsArrayBounds`), the pairs an access in the
 * block validated, and the loops' proofs (`IrLoopBounds`), made when an access first asks. One serves every function
 * lowered: `startFunction` and `startBlock` empty it.
 */
class HlArrayBounds {
	@:processWide("an empty set of calls known not to resize arrays, never added to")
	static final noPureCalls:Map<String, Bool> = [];

	var body:IrBody;
	var loops:Null<IrLoopBounds> = null;

	/** The block's pairs, numbered in the order first met; chained by array value from `heads`. */
	final pairIndices:Array<Int> = [];

	final pairNext:Array<Int> = [];

	/** The `proofs` stamp at which each pair was proved in range: it holds while the stamp is current. */
	final pairProofs:Array<Int> = [];

	final pairValidated:Array<Bool> = [];

	/** By array value id, the pair its chain starts at, valid when `headBlocks` has the current `block` stamp. */
	final heads:Array<Int> = [];

	final headBlocks:Array<Int> = [];
	var block = 0;
	var proofs = 0;

	public function new() {}

	/** Starts the function `body`: the loops' proofs of the previous one are dropped. */
	public function startFunction(body:IrBody):Void {
		this.body = body;
		loops = null;
	}

	/** Starts a block: nothing is proved or validated in it yet. */
	public function startBlock():Void {
		block++;
		if (block == 0x3FFFFFFF) {
			for (index in 0...headBlocks.length)
				headBlocks[index] = 0;
			block = 1;
		}
		proofs++;
		pairIndices.resize(0);
		pairNext.resize(0);
		pairProofs.resize(0);
		pairValidated.resize(0);
	}

	/** Steps past a row of opcode `opcode`: one that may run code or shrink an array forgets every proof. */
	public function step(opcode:IrOpcode):Void
		if (!HlLoweringDecisions.keepsArrayBounds(opcode))
			proofs++;

	/** Whether a check since the last row that may shrink `array` proved `index` in range of it. */
	public function isProven(array:IrValueId, index:IrValueId):Bool {
		var found = find(array, index);
		return found >= 0 && pairProofs[found] == proofs;
	}

	/** Whether an access earlier in the block validated `index` of `array`. */
	public function isValidated(array:IrValueId, index:IrValueId):Bool {
		var found = find(array, index);
		return found >= 0 && pairValidated[found];
	}

	public function prove(array:IrValueId, index:IrValueId):Void
		pairProofs[pair(array, index)] = proofs;

	public function validate(array:IrValueId, index:IrValueId):Void
		pairValidated[pair(array, index)] = true;

	/**
	 * The number of the pair `array` and `index` in the block, the same for every access to it: a backend keys what it keeps
	 * per pair by it.
	 */
	public function pair(array:IrValueId, index:IrValueId):Int {
		var found = find(array, index);
		if (found >= 0)
			return found;
		var id:Int = array;
		while (heads.length <= id) {
			heads.push(-1);
			headBlocks.push(0);
		}
		found = pairIndices.length;
		pairIndices.push((index:Int));
		pairNext.push(headBlocks[id] == block ? heads[id] : -1);
		pairProofs.push(proofs - 1);
		pairValidated.push(false);
		heads[id] = found;
		headBlocks[id] = block;
		return found;
	}

	/** Whether the loops around block `blockId` prove `index` in range of `array`. */
	public function provenByLoop(array:IrValueId, index:IrValueId, blockId:Int):Bool {
		var bounds = loops;
		if (bounds == null) {
			// The proofs read the function as objects: the body is decoded for them, once per function that asks.
			bounds = new IrLoopBounds(body.toFunction(), noPureCalls);
			loops = bounds;
		}
		return bounds.proven(valueOf(array), valueOf(index), blockId);
	}

	function find(array:IrValueId, index:IrValueId):Int {
		var id:Int = array;
		if (id >= heads.length || headBlocks[id] != block)
			return -1;
		var at = heads[id];
		while (at >= 0) {
			if (pairIndices[at] == (index:Int))
				return at;
			at = pairNext[at];
		}
		return -1;
	}

	function valueOf(value:IrValueId):IrValue
		return new IrValue(value, body.valueName(value), body.valueType(value));
}
