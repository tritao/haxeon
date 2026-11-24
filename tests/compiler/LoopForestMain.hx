import compiler.ir.analysis.IrLoopForest;
import compiler.ir.cfg.IrBodyGraph;
import compiler.ir.model.Ir;
import compiler.ir.model.IrBodyBuilder;
import compiler.ir.model.IrBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.model.SourceProvenance;
import compiler.ir.model.SourceProvenance.Located;

/** The loops of a body (`IrLoopForest`): nesting, innermost loops and membership. */
class LoopForestMain {
	static function expect(value:Bool, message:String):Void
		if (!value)
			throw message;

	/** Two nested counted loops: `i` from 0 by 1 outside, `j` from `n` by -2 inside. */
	static function main():Void {
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
		var body = IrBodyBuilder.encode(new IrFunction("loops", b.arguments, I32, b.blocks, Ordinary)),
			forest = new IrLoopForest(body, new IrBodyGraph().reset(body));
		expect(forest.count() == 2, 'two loops, found ${forest.count()}');
		var outerLoop = forest.loopOf(outer.id), innerLoop = forest.loopOf(inner.id);
		expect(outerLoop >= 0 && innerLoop >= 0 && outerLoop != innerLoop, "each header has its own loop");
		expect(forest.parent(innerLoop) == outerLoop && forest.depth(innerLoop) == 2,
			"the inner loop nests in the outer one");
		expect(forest.loopOf(latch.id) == outerLoop && forest.loopOf(innerBody.id) == innerLoop, "innermost loops");
		expect(forest.contains(outerLoop, innerBody.id) && !forest.contains(innerLoop, latch.id)
			&& forest.depthOf(exit.id) == 0, "membership");
	}
}
