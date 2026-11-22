import compiler.ir.analysis.IrBodyAnalysis;
import compiler.ir.model.Ir;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrBodyBuilder;
import compiler.ir.model.IrBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrTypeIds;
import compiler.ir.model.IrValueId;
import compiler.ir.model.SourceProvenance;
import compiler.ir.model.SourceProvenance.Located;

/** The shared analysis of a body (`IrBodyAnalysis`): rows, uses, dominance across try regions, the loop forest. */
class BodyAnalysisMain {
	static function expect(value:Bool, message:String):Void
		if (!value)
			throw message;

	/** The `index`th row of `opcode` in `body`'s block `block` (an index). */
	static function rowOf(body:IrBody, block:Int, opcode:IrOpcode, index = 0):Int {
		var row = body.firstRow(block);
		while (row >= 0) {
			if (body.opcode(row) == opcode && index-- == 0)
				return row;
			row = body.nextRow(row);
		}
		throw 'no $opcode in block $block';
	}

	static function main():Void {
		loops();
		tryRegions();
		cache();
	}

	/** Two nested counted loops: `i` from 0 by 1 outside, `j` from `n` by -2 inside. */
	static function loops():Void {
		var b = new IrBuilder(),
			n = b.argument("n", I32),
			zero = b.constInt(0),
			entry = b.currentBlock(),
			outer = b.createBlock(),
			inner = b.createBlock(),
			innerBody = b.createBlock(),
			latch = b.createBlock(),
			exit = b.createBlock();
		b.jump(outer);
		b.select(outer);
		var i = b.freshValue("i", I32),
			j = b.freshValue("j", I32),
			iNext = b.freshValue("iNext", I32),
			jNext = b.freshValue("jNext", I32);
		outer.instructions.push(new Located(IrInstruction.Phi(i, [
			{block: entry.id, value: zero},
			{block: latch.id, value: iNext}
		]),
			SourceProvenance.generated("test")));
		b.branch(b.less(i, n), inner, exit);
		b.select(inner);
		inner.instructions.push(new Located(IrInstruction.Phi(j, [
			{block: outer.id, value: n},
			{block: innerBody.id, value: jNext}
		]),
			SourceProvenance.generated("test")));
		b.branch(b.less(zero, j), innerBody, latch);
		b.select(innerBody);
		innerBody.instructions.push(new Located(IrInstruction.Sub(jNext, j, b.constInt(2)),
			SourceProvenance.generated("test")));
		b.jump(inner);
		b.select(latch);
		latch.instructions.push(new Located(IrInstruction.Add(iNext, i, b.constInt(1)),
			SourceProvenance.generated("test")));
		b.jump(outer);
		b.select(exit);
		b.returnValue(i);
		var body = IrBodyBuilder.encode(new IrFunction("loops", b.arguments, I32, b.blocks, Ordinary), new IrTypeIds()),
			analysis = IrBodyAnalysis.of(body),
			forest = analysis.loops();
		expect(forest.count() == 2, 'two loops, found ${forest.count()}');
		var outerLoop = forest.loopOf(outer.id), innerLoop = forest.loopOf(inner.id);
		expect(outerLoop >= 0 && innerLoop >= 0 && outerLoop != innerLoop, "each header has its own loop");
		expect(forest.parent(innerLoop) == outerLoop && forest.depth(innerLoop) == 2,
			"the inner loop nests in the outer one");
		expect(forest.loopOf(latch.id) == outerLoop && forest.loopOf(innerBody.id) == innerLoop, "innermost loops");
		expect(forest.contains(outerLoop, innerBody.id) && !forest.contains(innerLoop, latch.id)
			&& forest.depthOf(exit.id) == 0, "membership");
		expect(forest.inductionCount(outerLoop) == 1 && (forest.inductionValue(outerLoop, 0):Int) == i.id
			&& (forest.inductionInitial(outerLoop, 0):Int) == zero.id && forest.inductionStep(outerLoop, 0) == 1,
			"i starts at 0 and steps by 1");
		expect(forest.inductionCount(innerLoop) == 1 && (forest.inductionInitial(innerLoop, 0):Int) == n.id
			&& forest.inductionStep(innerLoop, 0) == -2, "j starts at n and steps by -2");
		// Uses: `i` is read by the comparison, the increment and the return.
		var uses = analysis.useCount(IrValueId.of(i.id));
		expect(uses == 3, 'i has three uses, found $uses');
		var compare = rowOf(body, 1, IrOpcode.Less), increment = rowOf(body, 4, IrOpcode.Add);
		expect(analysis.blockOf(compare) == 1 && analysis.blockOf(increment) == 4, "row blocks");
		expect(analysis.dominatesRow(compare, increment) && !analysis.dominatesRow(increment, compare),
			"the header dominates the latch, not the other way");
	}

	/** A row after a `BeginTry` of its block does not dominate the handler, nor what the handler reaches. */
	static function tryRegions():Void {
		var b = new IrBuilder(),
			object = b.argument("object", Obj("Box")),
			entry = b.currentBlock(),
			handler = b.createBlock(),
			after = b.createBlock(),
			where = SourceProvenance.generated("test");
		var before = b.fieldGet(object, "value", I32);
		entry.instructions.push(new Located(IrInstruction.BeginTry(handler.id, after.id, false), where));
		var inside = b.fieldGet(object, "value", I32);
		entry.instructions.push(new Located(IrInstruction.EndTry(handler.id, false), where));
		b.jump(after);
		b.select(handler);
		var caught = b.freshValue("caught", Dyn);
		handler.instructions.push(new Located(IrInstruction.Catch(caught), where));
		b.jump(after);
		b.select(after);
		var last = b.fieldGet(object, "value", I32);
		b.returnValue(b.add(before, b.add(inside, last)));
		var body = IrBodyBuilder.encode(new IrFunction("try", b.arguments, I32, b.blocks, Ordinary), new IrTypeIds()),
			analysis = IrBodyAnalysis.of(body),
			first = rowOf(body, 0, IrOpcode.FieldGet),
			second = rowOf(body, 0, IrOpcode.FieldGet, 1),
			handled = rowOf(body, 1, IrOpcode.Catch),
			merged = rowOf(body, 2, IrOpcode.FieldGet);
		expect(analysis.dominatesRow(first, handled) && analysis.dominatesRow(first, merged),
			"a row before the try dominates the handler and what follows");
		expect(!analysis.dominatesRow(second, handled) && !analysis.dominatesRow(second, merged),
			"a row inside the try dominates neither the handler nor the join it reaches");
	}

	/** The analysis is cached while the body has the edits it was made at, and made again after an edit. */
	static function cache():Void {
		var b = new IrBuilder(), x = b.argument("x", I32);
		b.returnValue(b.add(x, b.constInt(1)));
		var body = IrBodyBuilder.encode(new IrFunction("cached", b.arguments, I32, b.blocks, Ordinary),
			new IrTypeIds());
		var first = IrBodyAnalysis.of(body);
		expect(IrBodyAnalysis.of(body) == first, "the same analysis while the body is unchanged");
		body.removeRow(0, rowOf(body, 0, IrOpcode.ConstInt));
		expect(IrBodyAnalysis.of(body) != first, "a new analysis after an edit");
		IrBodyAnalysis.release(body);
	}
}
