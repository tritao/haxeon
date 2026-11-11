package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.IrValueLaneLayout.IrValueLaneShape;
import compiler.ir.IrValueLaneLayout.IrValueLaneSlot;
import compiler.ir.IrFunction.IrValueArraySlotOperation;

typedef IrValueArraySlotCopy = {final source:Int; final target:Int; final type:IrType;}
typedef IrValueArraySubslot = {final index:Int; final slot:IrValueLaneSlot;}

/** Field accessors for an array place: each call keeps the array and index live, never a pointer into a lane. */
class IrValueArraySlotHelpers {
	final namespace:Int;
	final element:IrType;
	final shape:IrValueLaneShape;
	final access:IrValueArrayAccess;
	final reads:Array<Null<String>>;
	final writes:Array<Null<String>>;
	final checks:Array<{name:String, path:Array<String>, includeSelf:Bool}> = [];
	final optionalWrites:Array<{name:String, path:Array<String>, type:IrType}> = [];
	final scalarChecks:Array<{name:String, type:IrType}> = [];
	var nextSymbol = 0;
	var built = false;

	public function new(namespace:Int, element:IrType, shape:IrValueLaneShape) {
		this.namespace = namespace;
		this.element = element;
		this.shape = shape;
		this.access = new IrValueArrayAccess(shape.scalarWordBits);
		this.reads = [for (_ in shape.slots) null];
		this.writes = [for (_ in shape.slots) null];
	}

	function nextName():String return '$' + 'haxeon_value_array_slot_${namespace}_${nextSymbol++}';

	public function getter(slot:Int):String {
		checkSlot(slot);
		if (reads[slot] == null) reads[slot] = nextName();
		return reads[slot];
	}
	public function setter(slot:Int):String {
		checkSlot(slot);
		if (writes[slot] == null) writes[slot] = nextName();
		return writes[slot];
	}

	/** Request a check before evaluating the rest of a place operation. */
	public function checker(path:Array<String>, includeSelf:Bool):String {
		for (index in 0...checks.length)
			if (checks[index].includeSelf == includeSelf && samePath(checks[index].path, path)) return checks[index].name;
		if (built) throw "Value lane place checks must be requested before generating helpers";
		var symbol = nextName();
		checks.push({name: symbol, path: path.copy(), includeSelf: includeSelf});
		return symbol;
	}

	/** Store an optional scalar from already-evaluated presence and payload components. */
	public function optionalSetter(path:Array<String>, type:IrType):String {
		var presence = slot(path, true), payload = slot(path, false, true);
		if (!Type.enumEq(shape.slots[presence].type, Bool) || !Type.enumEq(shape.slots[payload].type, type))
			throw 'Wrong optional scalar lane type for ${path.join(".")}';
		for (index in 0...optionalWrites.length)
			if (samePath(optionalWrites[index].path, path) && IrVerifier.sameType(optionalWrites[index].type, type))
				return optionalWrites[index].name;
		if (built) throw "Optional lane writes must be requested before generating helpers";
		var symbol = nextName();
		optionalWrites.push({name: symbol, path: path.copy(), type: type});
		return symbol;
	}

	/** Unwrap a saved optional scalar without rereading its array place after intervening calls. */
	public function requireScalar(type:IrType):String {
		switch type { case I32, I64, F32, F64, Bool: default: throw 'Invalid optional scalar payload $type'; }
		for (index in 0...scalarChecks.length)
			if (IrVerifier.sameType(scalarChecks[index].type, type)) return scalarChecks[index].name;
		if (built) throw "Optional scalar checks must be requested before generating helpers";
		var symbol = nextName();
		scalarChecks.push({name: symbol, type: type});
		return symbol;
	}

	static function samePath(left:Array<String>, right:Array<String>):Bool {
		if (left.length != right.length) return false;
		for (index in 0...left.length) if (left[index] != right[index]) return false;
		return true;
	}

	/** Resolve a logical field projection without confusing an optional's flag with its payload. */
	public function slot(path:Array<String>, presence:Bool = false, nullablePayload:Bool = false):Int {
		var found = -1;
		for (index in 0...shape.slots.length) {
			var candidate = shape.slots[index];
			if (candidate.isPresence != presence || candidate.nullablePayload != nullablePayload || candidate.path.length != path.length)
				continue;
			var same = true;
			for (part in 0...path.length) if (candidate.path[part] != path[part]) { same = false; break; }
			if (!same) continue;
			if (found >= 0) throw 'Ambiguous value lane path ${path.join(".")}';
			found = index;
		}
		if (found < 0) throw 'Missing value lane path ${path.join(".")}';
		return found;
	}

	/** Match all leaves of two value projections, including optional flags and payload slots. */
	public function copySlots(source:Array<String>, target:Array<String>):Array<IrValueArraySlotCopy> {
		var result:Array<IrValueArraySlotCopy> = [];
		for (targetIndex in 0...shape.slots.length) {
			var targetSlot = shape.slots[targetIndex];
			if (!isPrefix(target, targetSlot.path, true)) continue;
			var sourcePath = source.concat(targetSlot.path.slice(target.length));
			var sourceIndex = slot(sourcePath, targetSlot.isPresence, targetSlot.nullablePayload), sourceSlot = shape.slots[sourceIndex];
			if (!compatibleSlots(sourceSlot, targetSlot))
				throw 'Incompatible value lane projections ${source.join(".")} and ${target.join(".")}';
			result.push({source: sourceIndex, target: targetIndex, type: targetSlot.type});
		}
		var sourceCount = 0;
		for (candidate in shape.slots) if (isPrefix(source, candidate.path, true)) sourceCount++;
		if (sourceCount != result.length) throw 'Incompatible value lane projections ${source.join(".")} and ${target.join(".")}';
		return result;
	}

	public function subtree(path:Array<String>):Array<IrValueArraySubslot> {
		return [for (index in 0...shape.slots.length) if (isPrefix(path, shape.slots[index].path, true))
			{index: index, slot: shape.slots[index]}];
	}

	static function compatibleSlots(left:IrValueLaneSlot, right:IrValueLaneSlot):Bool
		return IrVerifier.sameType(left.type, right.type) && left.isReference == right.isReference
			&& left.bitWidth == right.bitWidth && left.signed == right.signed;

	/** Generate one typed read and write function per lane leaf. Neither function allocates a value box. */
	public function functions():Array<IrFunction> {
		built = true;
		var result:Array<IrFunction> = [];
		for (index in 0...shape.slots.length) {
			var slot = shape.slots[index];
			var read = new IrBuilder(), readArray = read.argument("array", Array(element)), readIndex = read.argument("index", I32);
			read.returnValue(access.read(read, readArray, readIndex, slot));
			result.push(new IrFunction(getter(index), read.arguments, slot.type, read.blocks, ValueArraySlot(namespace, element, Read(index, slot.path.copy(), IrValueLaneReference.isCarrier(slot.type)))));
			var write = new IrBuilder(), writeArray = write.argument("array", Array(element)), writeIndex = write.argument("index", I32),
				value = write.argument("value", slot.type);
			if (slot.isPresence) {
				var present = write.createBlock(), absent = write.createBlock(), done = write.createBlock();
				write.branch(value, present, absent);
				write.select(present);
				access.write(write, writeArray, writeIndex, slot, value);
				write.jump(done);
				write.select(absent);
				for (other in 0...shape.slots.length) if (other != index && isPrefix(slot.path, shape.slots[other].path, true))
					access.clear(write, writeArray, writeIndex, shape.slots[other]);
				access.write(write, writeArray, writeIndex, slot, value);
				write.jump(done);
				write.select(done);
			} else
				access.write(write, writeArray, writeIndex, slot, value);
			write.returnValue(write.constVoid());
			result.push(new IrFunction(setter(index), write.arguments, Void, write.blocks, ValueArraySlot(namespace, element, Write(index, slot.path.copy(), IrValueLaneReference.isCarrier(slot.type)))));
		}
		for (requestIndex in 0...checks.length) {
			var request = checks[requestIndex], builder = new IrBuilder(), array = builder.argument("array", Array(element)),
				index = builder.argument("index", I32);
			builder.call("__value_array_validate", [array, index], Void);
			for (slot in shape.slots) if (slot.isPresence && isPrefix(slot.path, request.path, request.includeSelf)) {
				var present = access.read(builder, array, index, slot), yes = builder.createBlock(), no = builder.createBlock();
				builder.branch(present, yes, no);
				builder.select(no);
				builder.terminate(Throw(builder.toDyn(builder.constString("Null access"))));
				builder.select(yes);
			}
			builder.returnValue(builder.constVoid());
			result.push(new IrFunction(request.name, builder.arguments, Void, builder.blocks, ValueArraySlot(namespace, element, Check(request.path.copy(), request.includeSelf))));
		}
		for (requestIndex in 0...optionalWrites.length) {
			var request = optionalWrites[requestIndex], builder = new IrBuilder(), array = builder.argument("array", Array(element)),
				index = builder.argument("index", I32), present = builder.argument("present", Bool), payload = builder.argument("payload", request.type),
				yes = builder.createBlock(), no = builder.createBlock(), done = builder.createBlock();
			builder.branch(present, yes, no);
			builder.select(yes);
			builder.call(setter(slot(request.path, false, true)), [array, index, payload], Void);
			builder.call(setter(slot(request.path, true)), [array, index, builder.constBool(true)], Void);
			builder.jump(done);
			builder.select(no);
			builder.call(setter(slot(request.path, true)), [array, index, builder.constBool(false)], Void);
			builder.jump(done);
			builder.select(done); builder.returnValue(builder.constVoid());
			result.push(new IrFunction(request.name, builder.arguments, Void, builder.blocks, ValueArraySlot(namespace, element, OptionalWrite(request.path.copy(), request.type))));
		}
		for (requestIndex in 0...scalarChecks.length) {
			var request = scalarChecks[requestIndex], type = request.type, builder = new IrBuilder(), present = builder.argument("present", Bool),
				payload = builder.argument("payload", type), yes = builder.createBlock(), no = builder.createBlock();
			builder.branch(present, yes, no);
			builder.select(yes); builder.returnValue(payload);
			builder.select(no); builder.terminate(Throw(builder.toDyn(builder.constString("Null access"))));
			result.push(new IrFunction(request.name, builder.arguments, type, builder.blocks, ValueArraySlot(namespace, element, RequireScalar(type))));
		}
		return result;
	}

	/** Call after `functions()`, which collects precisely the native operations those functions use. */
	public function natives():Array<IrNative> {
		if (!built) throw "Value lane helpers must be generated before collecting natives";
		var result = access.natives();
		if (checks.length > 0) result.push({name: "__value_array_validate", library: "haxeon_runtime", symbol: "__value_array_validate",
			arguments: [Array(Dyn), I32], result: Void});
		return result;
	}

	static function isPrefix(prefix:Array<String>, path:Array<String>, includeSelf:Bool):Bool {
		if (prefix.length > path.length || (!includeSelf && prefix.length == path.length)) return false;
		for (index in 0...prefix.length) if (prefix[index] != path[index]) return false;
		return true;
	}

	function checkSlot(slot:Int):Void {
		if (slot < 0 || slot >= shape.slots.length) throw 'Invalid value lane slot $slot';
	}

}
