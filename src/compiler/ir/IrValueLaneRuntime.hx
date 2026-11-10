package compiler.ir;

import compiler.ir.Ir;

/**
 * Structural policy for scalar/reference lane arrays. The storage primitives own GC barriers and
 * physical addressing; these functions own bounds, growth, overlap, validity and publication order.
 * The same SSA functions are consumed by Wasm and the native-runtime C generator.
 */
class IrValueLaneRuntime {
	public static inline final PREFIX = "$lane-runtime:";
	public static inline final PRIMITIVE = "$lane-storage:";
	static final array:IrType = Array(Dyn);

	public static function functions(roundSparseCapacity:Bool = true):Array<IrFunction> return [
		capacityFor(roundSparseCapacity), reserve(), prepareWrite(), ensure(), clearElement(), clearRange(), move(), resize(), insert(), removeAt(),
		copy(), slice(), concat(), splice(), reverse()
	];

	public static function primitives():Array<IrNative> {
		function entry(name:String, arguments:Array<IrType>, result:IrType):IrNative
			return {name: PRIMITIVE + name, library: "haxeon_runtime", symbol: "__lane_storage_" + name.split("-").join("_"),
				arguments: arguments, result: result};
		return [
			entry("length", [array], I32), entry("capacity", [array], I32), entry("has-validity", [array], Bool),
			entry("publish-length", [array, I32], Void), entry("replace-capacity", [array, I32, Bool], Void),
			entry("new-like", [array, I32], array), entry("compatible", [array, array], Bool), entry("fail", [I32], Void),
			entry("clear-scalars", [array, I32, I32], Void), entry("clear-references", [array, I32, I32], Void),
			entry("copy-scalars", [array, I32, array, I32, I32], Void), entry("copy-references", [array, I32, array, I32, I32], Void),
			entry("swap-scalars", [array, I32, I32], Void), entry("swap-references", [array, I32, I32], Void),
			entry("read-validity", [array, I32], Bool), entry("write-validity", [array, I32, Bool], Void)
		];
	}

	public static function program(roundSparseCapacity:Bool = true):IrProgram {
		var result = new IrProgram(PREFIX + "reserve");
		result.functions = functions(roundSparseCapacity); result.natives = primitives();
		IrVerifier.verify(result);
		return result;
	}

	static function finish(b:IrBuilder, name:String, result:IrType):IrFunction
		return new IrFunction(PREFIX + name, b.arguments, result, b.blocks, GeneratedHelper);
	static function primitive(b:IrBuilder, name:String, args:Array<IrValue>, result:IrType):IrValue
		return b.call(PRIMITIVE + name, args, result);
	static function call(b:IrBuilder, name:String, args:Array<IrValue>, result:IrType = Void):IrValue
		return b.call(PREFIX + name, args, result);
	static function length(b:IrBuilder, a:IrValue):IrValue return primitive(b, "length", [a], I32);
	static function publish(b:IrBuilder, a:IrValue, size:IrValue):Void primitive(b, "publish-length", [a, size], Void);
	static function newLike(b:IrBuilder, a:IrValue, size:IrValue):IrValue return primitive(b, "new-like", [a, size], array);

	static function guard(b:IrBuilder, valid:IrValue, error:Int):Void {
		var yes = b.createBlock(), no = b.createBlock();
		b.branch(valid, yes, no);
		b.select(no);
		primitive(b, "fail", [b.constInt(error)], Void);
		b.throwValue(b.constNull(Dyn));
		b.select(yes);
	}

	/** Select without evaluating either branch twice or relying on mutable IR registers. */
	static function choose(b:IrBuilder, condition:IrValue, yes:Void->IrValue, no:Void->IrValue):IrValue {
		var a = b.createBlock(), z = b.createBlock(), join = b.createBlock();
		b.branch(condition, a, z);
		b.select(a); var x = yes(), xp = b.currentBlock().id; b.jump(join);
		b.select(z); var y = no(), yp = b.currentBlock().id; b.jump(join);
		b.select(join);
		return b.phi(x.type, [{block: xp, value: x}, {block: yp, value: y}]);
	}

	static function when(b:IrBuilder, condition:IrValue, body:Void->Void):Void {
		var work = b.createBlock(), done = b.createBlock();
		b.branch(condition, work, done); b.select(work); body(); b.jump(done); b.select(done);
	}

	static function loop(b:IrBuilder, first:IrValue, end:IrValue, body:IrValue->Void):Void {
		var incoming:Array<IrPhiInput> = [{block: b.currentBlock().id, value: first}],
			header = b.createBlock(), work = b.createBlock(), done = b.createBlock();
		b.jump(header); b.select(header);
		var index = b.phi(I32, incoming);
		b.branch(b.less(index, end), work, done);
		b.select(work); body(index);
		var next = b.add(index, b.constInt(1));
		incoming.push({block: b.currentBlock().id, value: next});
		b.jump(header); b.select(done);
	}

	static function capacityFor(roundSparseCapacity:Bool):IrFunction {
		var b = new IrBuilder(), a = b.argument("array", array), required = b.argument("capacity", I32),
			capacity = primitive(b, "capacity", [a], I32), done = b.createBlock(), grow = b.createBlock();
		b.branch(b.lessEqual(required, capacity), done, grow);
		b.select(done); b.returnValue(capacity);
		b.select(grow);
		var initial = roundSparseCapacity ? choose(b, b.less(capacity, b.constInt(4)), () -> b.constInt(4), () -> capacity) : capacity,
			incoming:Array<IrPhiInput> = [{block: b.currentBlock().id, value: initial}],
			header = b.createBlock(), advance = b.createBlock(), allocate = b.createBlock();
		b.jump(header); b.select(header);
		var next = b.phi(I32, incoming);
		b.branch(b.less(next, required), advance, allocate);
		b.select(advance);
		var half = b.div(next, b.constInt(2)),
			grown = choose(b, b.less(b.sub(b.constInt(0x7fffffff), half), next), () -> required, () -> b.add(next, half));
		// Wasm allocators jump straight to sparse requests; native retains its established geometric capacities.
		if (!roundSparseCapacity) grown = choose(b, b.less(grown, required), () -> required, () -> grown);
		incoming.push({block: b.currentBlock().id, value: grown});
		b.jump(header); b.select(allocate);
		b.returnValue(next);
		return finish(b, "capacity-for", I32);
	}

	static function reserve():IrFunction {
		var b = new IrBuilder(), a = b.argument("array", array), required = b.argument("capacity", I32),
			capacity = call(b, "capacity-for", [a, required], I32);
		primitive(b, "replace-capacity", [a, capacity, b.constBool(false)], Void);
		b.returnValue(b.constVoid()); return finish(b, "reserve", Void);
	}

	/** All conversions and leaf snapshots precede this transaction. No allocation follows its commit. */
	static function prepareWrite():IrFunction {
		var b = new IrBuilder(), a = b.argument("array", array), index = b.argument("index", I32),
			inserting = b.argument("insert", Bool), references = b.argument("references", Bool),
			size = length(b, a), insertBlock = b.createBlock(), storeBlock = b.createBlock(), done = b.createBlock();
		b.branch(inserting, insertBlock, storeBlock);
		b.select(insertBlock); guard(b, b.less(size, b.constInt(0x7fffffff)), 2);
		var next = b.add(size, b.constInt(1)), capacity = call(b, "capacity-for", [a, next], I32);
		primitive(b, "replace-capacity", [a, capacity, references], Void);
		var position = call(b, "insert", [a, index], I32), inserted = b.currentBlock().id; b.jump(done);
		b.select(storeBlock); guard(b, b.lessEqual(b.constInt(0), index), 0);
		guard(b, b.less(index, b.constInt(0x7fffffff)), 0);
		var required = choose(b, b.less(index, size), () -> size, () -> b.add(index, b.constInt(1))),
			storeCapacity = call(b, "capacity-for", [a, required], I32);
		primitive(b, "replace-capacity", [a, storeCapacity, references], Void);
		call(b, "ensure", [a, index]); var stored = b.currentBlock().id; b.jump(done);
		b.select(done); b.returnValue(b.phi(I32, [{block: inserted, value: position}, {block: stored, value: index}]));
		return finish(b, "prepare-write", I32);
	}

	static function ensure():IrFunction {
		var b = new IrBuilder(), a = b.argument("array", array), index = b.argument("index", I32);
		guard(b, b.lessEqual(b.constInt(0), index), 0);
		guard(b, b.less(index, b.constInt(0x7fffffff)), 0);
		var grow = b.createBlock(), done = b.createBlock();
		b.branch(b.less(index, length(b, a)), done, grow);
		b.select(grow); var size = b.add(index, b.constInt(1));
		call(b, "reserve", [a, size]); publish(b, a, size); b.jump(done);
		b.select(done); b.returnValue(b.constVoid());
		return finish(b, "ensure", Void);
	}

	static function clearElement():IrFunction {
		var b = new IrBuilder(), a = b.argument("array", array), index = b.argument("index", I32);
		guard(b, b.lessEqual(b.constInt(0), index), 0); guard(b, b.less(index, length(b,a)), 0);
		call(b, "clear-range", [a,index,b.constInt(1)]); b.returnValue(b.constVoid());
		return finish(b,"clear-element",Void);
	}

	static function clearRange():IrFunction {
		var b = new IrBuilder(), a = b.argument("array", array), first = b.argument("first", I32), count = b.argument("count", I32);
		primitive(b, "clear-scalars", [a, first, count], Void);
		primitive(b, "clear-references", [a, first, count], Void);
		when(b, primitive(b, "has-validity", [a], Bool), () ->
			loop(b, first, b.add(first, count), index -> primitive(b, "write-validity", [a, index, b.constBool(false)], Void)));
		b.returnValue(b.constVoid());
		return finish(b, "clear-range", Void);
	}

	static function move():IrFunction {
		var b = new IrBuilder(), to = b.argument("target", array), target = b.argument("target-index", I32),
			from = b.argument("source", array), source = b.argument("source-index", I32), count = b.argument("count", I32);
		primitive(b, "copy-scalars", [to, target, from, source, count], Void);
		primitive(b, "copy-references", [to, target, from, source, count], Void);
		when(b, primitive(b, "has-validity", [from], Bool), () -> {
			var backward = choose(b, b.equal(to, from), () -> b.less(source, target), () -> b.constBool(false));
			loop(b, b.constInt(0), count, index -> {
				var offset = choose(b, backward, () -> b.sub(b.sub(count, b.constInt(1)), index), () -> index),
					valid = primitive(b, "read-validity", [from, b.add(source, offset)], Bool);
				primitive(b, "write-validity", [to, b.add(target, offset), valid], Void);
			});
		});
		b.returnValue(b.constVoid());
		return finish(b, "move", Void);
	}

	static function resize():IrFunction {
		var b = new IrBuilder(), a = b.argument("array", array), size = b.argument("length", I32);
		guard(b, b.lessEqual(b.constInt(0), size), 1);
		var old = length(b, a), grow = b.createBlock(), shrink = b.createBlock(), done = b.createBlock();
		b.branch(b.less(old, size), grow, shrink);
		b.select(grow); call(b, "reserve", [a, size]); b.jump(done);
		b.select(shrink); call(b, "clear-range", [a, size, b.sub(old, size)]); b.jump(done);
		b.select(done); publish(b, a, size); b.returnValue(b.constVoid());
		return finish(b, "resize", Void);
	}

	static function insert():IrFunction {
		var b = new IrBuilder(), a = b.argument("array", array), input = b.argument("position", I32), size = length(b, a);
		guard(b, b.less(size, b.constInt(0x7fffffff)), 2);
		var adjusted = choose(b, b.less(input, b.constInt(0)), () -> b.add(input, size), () -> input),
			positive = choose(b, b.less(adjusted, b.constInt(0)), () -> b.constInt(0), () -> adjusted),
			position = choose(b, b.less(size, positive), () -> size, () -> positive), next = b.add(size, b.constInt(1));
		call(b, "reserve", [a, next]); publish(b, a, next);
		call(b, "move", [a, b.add(position, b.constInt(1)), a, position, b.sub(size, position)]);
		call(b, "clear-range", [a, position, b.constInt(1)]);
		b.returnValue(position);
		return finish(b, "insert", I32);
	}

	static function removeAt():IrFunction {
		var b = new IrBuilder(), a = b.argument("array", array), index = b.argument("index", I32), size = length(b, a);
		guard(b, b.lessEqual(b.constInt(0), index), 0); guard(b, b.less(index, size), 0);
		var next = b.add(index, b.constInt(1));
		call(b, "move", [a, index, a, next, b.sub(size, next)]);
		call(b, "resize", [a, b.sub(size, b.constInt(1))]);
		b.returnValue(b.constVoid());
		return finish(b, "remove-at", Void);
	}

	static function copy():IrFunction {
		var b = new IrBuilder(), a = b.argument("array", array), size = length(b, a), result = newLike(b, a, size);
		call(b, "move", [result, b.constInt(0), a, b.constInt(0), size]); b.returnValue(result);
		return finish(b, "copy", array);
	}

	static function slice():IrFunction {
		var b = new IrBuilder(), a = b.argument("array", array), start = b.argument("start", I32), end = b.argument("end", I32), size = length(b, a);
		function bound(value:IrValue):IrValue {
			var relative = choose(b, b.less(value, b.constInt(0)), () -> b.add(value, size), () -> value),
				positive = choose(b, b.less(relative, b.constInt(0)), () -> b.constInt(0), () -> relative);
			return choose(b, b.less(size, positive), () -> size, () -> positive);
		}
		var first = bound(start), last = bound(end), stop = choose(b, b.less(last, first), () -> first, () -> last),
			count = b.sub(stop, first), result = newLike(b, a, count);
		call(b, "move", [result, b.constInt(0), a, first, count]); b.returnValue(result);
		return finish(b, "slice", array);
	}

	static function concat():IrFunction {
		var b = new IrBuilder(), a = b.argument("left", array), z = b.argument("right", array);
		guard(b, primitive(b, "compatible", [a, z], Bool), 3);
		var left = length(b, a), right = length(b, z);
		guard(b, b.lessEqual(right, b.sub(b.constInt(0x7fffffff), left)), 2);
		var result = newLike(b, a, b.add(left, right));
		call(b, "move", [result, b.constInt(0), a, b.constInt(0), left]);
		call(b, "move", [result, left, z, b.constInt(0), right]); b.returnValue(result);
		return finish(b, "concat", array);
	}

	static function splice():IrFunction {
		var b = new IrBuilder(), a = b.argument("array", array), input = b.argument("position", I32), requested = b.argument("length", I32), size = length(b, a),
			empty = b.createBlock(), check = b.createBlock(), remove = b.createBlock();
		b.branch(b.less(requested, b.constInt(0)), empty, check);
		b.select(check); b.branch(b.less(size, input), empty, remove);
		b.select(empty); b.returnValue(newLike(b, a, b.constInt(0)));
		b.select(remove);
		var relative = choose(b, b.less(input, b.constInt(0)), () -> b.add(input, size), () -> input),
			position = choose(b, b.less(relative, b.constInt(0)), () -> b.constInt(0), () -> relative), available = b.sub(size, position),
			count = choose(b, b.less(available, requested), () -> available, () -> requested), result = newLike(b, a, count),
			next = b.add(position, count);
		call(b, "move", [result, b.constInt(0), a, position, count]);
		call(b, "move", [a, position, a, next, b.sub(size, next)]);
		call(b, "resize", [a, b.sub(size, count)]); b.returnValue(result);
		return finish(b, "splice", array);
	}

	static function reverse():IrFunction {
		var b = new IrBuilder(), a = b.argument("array", array), size = length(b, a), end = b.div(size, b.constInt(2)),
			withBitmap = b.createBlock(), withoutBitmap = b.createBlock(), done = b.createBlock();
		b.branch(primitive(b, "has-validity", [a], Bool), withBitmap, withoutBitmap);
		function swaps(validity:Bool):Void loop(b, b.constInt(0), end, left -> {
			var right = b.sub(b.sub(size, b.constInt(1)), left), l:Null<IrValue> = null, r:Null<IrValue> = null;
			if (validity) { l = primitive(b, "read-validity", [a, left], Bool); r = primitive(b, "read-validity", [a, right], Bool); }
			primitive(b, "swap-scalars", [a, left, right], Void);
			primitive(b, "swap-references", [a, left, right], Void);
			if (validity) {
				primitive(b, "write-validity", [a, left, r], Void);
				primitive(b, "write-validity", [a, right, l], Void);
			}
		});
		b.select(withBitmap); swaps(true); b.jump(done);
		b.select(withoutBitmap); swaps(false); b.jump(done);
		b.select(done); b.returnValue(b.constVoid());
		return finish(b, "reverse", Void);
	}
}
