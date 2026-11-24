package compiler.ir.passes.values;

import compiler.core.InternalError;
import compiler.ir.cfg.IrBodyGraph;
import compiler.ir.model.Ir;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrObjectTable;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrPassScratch;
import compiler.ir.model.IrSymbol;
import compiler.ir.model.IrValueId;
import compiler.ir.model.SourceProvenance;
import compiler.ir.passes.scalars.IrScalarReplacement;
import compiler.ir.passes.values.IrInlineValueLayout.IrInlineValueSlot;

/** Split a value phi into scalar snapshots when every incoming value is known to exist. */
@:nullSafety(Strict)
class IrValuePhiScalarization {
	/** `rewriteBodies` with fresh scratch, the result owned by the next stage. */
	public static function rewrite(program:IrProgram):Void
		rewriteBodies(program, new IrPassScratch());

	/**
	 * Splits the value phis of `program`'s functions on bodies (docs/design/IR_CORE_COLUMNS.md, migration): each function is read
	 * as its body (`encodedBody`), which this stage encodes when it is the pipeline's first over bodies. A function that
	 * changes becomes its edited body: owned by the next stage (edited in place, or a copy when a cache holds the body); one
	 * nothing changes stays the same object.
	 */
	public static function rewriteBodies(program:IrProgram, scratch:IrPassScratch):Void
		program.functions = compiler.ir.pipeline.IrFunctionStages.apply("value-phi-scalarization",
			pass(program, scratch),
			program.functions);

	/** `rewriteBodies` per function (`IrValueObjectRows`): a function with a value phi is rewritten. */
	public static function pass(program:IrProgram, scratch:IrPassScratch,
			?lineage:compiler.ir.reuse.IrStageMemo.IrLineage):IrValueObjectRows {
		var objects:Map<String, IrObject> = [for (object in program.objects) object.name => object];
		var table = IrObjectTable.of(objects),
			layouts = new IrInlineValueLayout(table),
			packets = [
				for (declaration in program.enums)
					if (declaration.inlineStorage != null) declaration.inlineStorage => true
			];
		return new IrValueObjectRows(
			IrOpcode.Phi,
			table,
			scratch.bodyBuilder,
			fn -> rewriteBody(fn, objects, table, layouts, packets, scratch),
			// What a rewrite reads of the declarations: the value objects, and which of them are enum packets.
			IrInlineValueLayout.declarationsFact(program.objects, lineage,
				"\npackets " + [for (declaration in program.enums) declaration.inlineStorage].join(","))
		);
	}

	/** `runBody` on `fn`'s body: `fn` itself when nothing changes. */
	public static function rewriteBody(fn:IrFunction, objects:Map<String, IrObject>, table:IrObjectTable,
			layouts:IrInlineValueLayout, alwaysPresent:Null<Map<String, Bool>>,
			scratch:IrPassScratch):IrFunction {
		var builder = scratch.bodyBuilder, body = fn.encodedBody(builder);
		if (!hasValuePhi(body, objects))
			return fn;
		var edited = body.forEditing(builder), before = edited.edits;
		var result = new IrBodyValuePhis(objects, table, layouts, alwaysPresent, scratch).run(edited);
		if (result == edited && edited.edits == before)
			return fn;
		return IrFunction.ofOwnedBody(result);
	}

	/**
	 * Drops chains of one-input value phis in `body`, which the caller owns, and splits the value phis whose inputs can be
	 * snapshotted, when scalar replacement then removes every split value's allocation: `body`, or the copy the split was made on.
	 */
	public static function runBody(body:IrBody, objects:Map<String, IrObject>, table:IrObjectTable,
			layouts:IrInlineValueLayout, alwaysPresent:Null<Map<String, Bool>>, scratch:IrPassScratch):IrBody
		return hasValuePhi(body, objects) ? new IrBodyValuePhis(objects, table, layouts, alwaysPresent,
			scratch).run(body) : body;

	static function hasValuePhi(body:IrBody, objects:Map<String, IrObject>):Bool {
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.Phi && valueObject(body.valueType(body.output(row)), objects) != null)
					return true;
				row = body.nextRow(row);
			}
		}
		return false;
	}

	static function valueObject(type:IrType, objects:Map<String, IrObject>):Null<String>
		return switch type {
			case Obj(name):
				var object = objects.get(name);
				object != null && object.isValue ? name : null;
			default: null;
		};
}

/** Value phi scalarization of one body, in place. */
@:nullSafety(Strict)
private class IrBodyValuePhis {
	final objects:Map<String, IrObject>;
	final table:IrObjectTable;
	final layouts:IrInlineValueLayout;
	final alwaysPresent:Null<Map<String, Bool>>;
	final scratch:IrPassScratch;

	public function new(objects:Map<String, IrObject>, table:IrObjectTable, layouts:IrInlineValueLayout,
			alwaysPresent:Null<Map<String, Bool>>, scratch:IrPassScratch) {
		this.objects = objects;
		this.table = table;
		this.layouts = layouts;
		this.alwaysPresent = alwaysPresent;
		this.scratch = scratch;
	}

	inline function valueName(body:IrBody, value:IrValueId):Null<String>
		return @:privateAccess IrValuePhiScalarization.valueObject(body.valueType(value), objects);

	inline function packet(name:Null<String>):Bool
		return alwaysPresent != null && name != null && alwaysPresent.exists(name);

	/**
	 * Drops chains of one-input value phis, then splits the value phis whose inputs can be snapshotted: on a copy of `body`,
	 * kept when scalar replacement then removes every split value's allocation. The result: that copy, or `body`.
	 */
	public function run(body:IrBody):IrBody {
		dropSingles(body);
		var plans = plan(body);
		if (plans.length == 0)
			return body;
		var attempt = body.thaw(scratch.bodyBuilder);
		split(attempt, plans);
		IrScalarReplacement.runBody(attempt, table, scratch, true, true);
		var planned:Map<Int, Bool> = [for (plan in plans) plan.output => true];
		for (block in 0...attempt.blockCount()) {
			var row = attempt.firstRow(block);
			while (row >= 0) {
				if (attempt.opcode(row) == IrOpcode.ValueInit) {
					var out = attempt.output(row);
					if (planned.exists(out) && !packet(valueName(attempt, out)))
						return body;
				}
				row = attempt.nextRow(row);
			}
		}
		return attempt;
	}

	/** Inlining nested generated boundaries can leave chains of one-input value phis, which hide allocations from the split. */
	function dropSingles(body:IrBody):Void {
		var singles:Map<Int, Int> = [];
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.Phi && valueName(body, body.output(row)) != null) {
					var out:Int = body.output(row);
					if (body.operandCount(row) == 1 && out != (body.operand(row, 0):Int))
						singles.set(out, body.operand(row, 0));
				}
				row = body.nextRow(row);
			}
		}
		var substitutions:Map<Int, Int> = [];
		for (id => value in singles) {
			var seen:Map<Int, Bool> = [id => true], current = value, valid = true;
			while (true) {
				var next = singles.get(current);
				if (next == null)
					break;
				if (seen.exists(current)) {
					valid = false;
					break;
				}
				seen.set(current, true);
				current = next;
			}
			if (valid)
				substitutions.set(id, current);
		}
		if (!substitutions.keys().hasNext())
			return;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var next = body.nextRow(row);
				if (body.opcode(row) == IrOpcode.Phi && substitutions.exists(body.output(row)))
					body.removeRow(block, row);
				row = next;
			}
		}
		for (id => value in substitutions)
			body.alias(IrValueId.of(id), IrValueId.of(value));
		body.sweepAliases();
	}

	/** The value phis to split, in layout order: each by its output and the id of its block. */
	function plan(body:IrBody):Array<{output:Int, block:Int}> {
		var known:Map<Int, Bool> = [];
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.ValueInit && valueName(body, body.output(row)) != null)
					known.set(body.output(row), true);
				row = body.nextRow(row);
			}
		}
		var plans:Array<{output:Int, block:Int}> = [], graph:Null<IrBodyGraph> = null;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block), id = body.blockId(block);
			while (row >= 0) {
				var out = body.output(row);
				if (body.opcode(row) == IrOpcode.Phi && valueName(body, out) != null) {
					var isPacket = packet(valueName(body, out)), count = body.operandCount(row), valid = count > 0;
					for (index in 0...count) {
						var from = body.auxInt(row, index),
							value = body.operand(row, index),
							predecessor = body.blockIndex(from),
							terminator = predecessor < 0 ? -1 : body.terminatorRow(predecessor);
						if (terminator < 0
							|| (!isPacket && !known.exists(value))
							|| body.valueTypeId(value) != body.valueTypeId(out))
							valid = false;
						else {
							if (!isPacket) {
								if (graph == null)
									graph = scratch.bodyGraph.reset(body);
								if (!isolated(body, graph, value, from, id, out))
									valid = false;
							}
							if (valid)
								switch body.opcode(terminator) {
									case IrOpcode.Jump if (body.aux(terminator) == id):
									case IrOpcode.Branch if (isPacket
										&& (body.auxInt(terminator, 0) == id || body.auxInt(terminator, 1) == id)):
									default: valid = false;
								}
						}
					}
					if (valid)
						plans.push({output: out, block: id});
				}
				row = body.nextRow(row);
			}
		}
		return plans;
	}

	/**
	 * Whether `input`, reaching phi `output` of block `destination` from block `from`, is read only by field accesses that come
	 * before that edge: construction can span several blocks, but a later access could observe an alias of the snapshot.
	 */
	function isolated(body:IrBody, graph:IrBodyGraph, input:IrValueId, from:Int, destination:Int,
			output:IrValueId):Bool {
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block), id = body.blockId(block);
			while (row >= 0) {
				var opcode = body.opcode(row);
				if (opcode.isTerminator()) {
					switch opcode {
						case IrOpcode.Return, IrOpcode.Throw, IrOpcode.Rethrow, IrOpcode.Branch:
							if (body.operand(row, 0) == input)
								return false;
						default:
					}
				} else if (opcode == IrOpcode.Phi) {
					// A phi's inputs are edge uses, which only this check covers.
					for (index in 0...body.operandCount(row))
						if (body.operand(row, index) == input
							&& (body.output(row) != output || id != destination || body.auxInt(row, index) != from))
							return false;
				} else {
					var used = false;
					for (index in 0...body.operandCount(row))
						if (body.operand(row, index) == input)
							used = true;
					if (used) {
						if (!graph.dominates(id, from))
							return false;
						switch opcode {
							case IrOpcode.FieldGet if (body.operand(row, 0) == input):
							case IrOpcode.FieldSet if (body.operand(row, 0) == input && body.operand(row, 1) != input):
							default:
								return false;
						}
					}
				}
				row = body.nextRow(row);
			}
		}
		return true;
	}

	function declared(type:IrType, field:String):IrObjectField {
		var name:Null<String> = switch type {
			case Obj(value): value;
			default: throw new InternalError("Invalid value phi field");
		};
		while (name != null) {
			var object = objects.get(name);
			if (object == null)
				break;
			for (candidate in object.fields)
				if (candidate.name == field)
					return candidate;
			name = object.base;
		}
		throw new InternalError('Missing value phi field "$field"');
	}

	function optionalValue(field:IrObjectField):Bool
		return switch field.type {
			case Nullable(Obj(name)):
				var object = objects.get(name);
				object != null && object.isValue;
			default: false;
		};

	function fieldGet(body:IrBody, output:IrValueId, owner:IrValueId, field:String, provenance:SourceProvenance):Int {
		body.beginRow();
		body.pushOperand(owner);
		return body.endRow(IrOpcode.FieldGet, output, IrSymbol.of(field).id, provenance);
	}

	/**
	 * Splits each planned phi: its inputs' fields read at the end of each predecessor, one scalar phi per field after the block's
	 * other phis, and the value made again from them after the scalar phis.
	 */
	function split(body:IrBody, plans:Array<{output:Int, block:Int}>):Void {
		var count = body.blockCount();
		var reads:Array<Array<Int>> = [for (_ in 0...count)[]],
			phis:Array<Array<Int>> = [for (_ in 0...count)[]],
			setups:Array<Array<Int>> = [for (_ in 0...count)[]],
			removed:Array<Int> = [];
		for (plan in plans) {
			var out = IrValueId.of(plan.output),
				row = body.definingRow(out),
				where = body.provenance(row),
				shape = layouts.slots(body.valueType(out)),
				target = body.blockIndex(plan.block);
			var inputs:Array<Array<Int>> = [for (_ in shape)[]];
			for (index in 0...body.operandCount(row)) {
				var from = body.auxInt(row, index), predecessor = body.blockIndex(from);
				for (slotIndex in 0...shape.length) {
					var current = body.operand(row, index), slot = shape[slotIndex];
					for (partIndex in 0...slot.path.length) {
						var part = slot.path[partIndex], field = declared(body.valueType(current), part);
						if (optionalValue(field)) {
							var sub:IrInlineValueSlot = {
								path: slot.path.slice(partIndex + 1),
								type: slot.type,
								isPresence: slot.isPresence,
								nativeLayout: slot.nativeLayout
							};
							var read = body.newValue("$value-phi-read", body.typeId(slot.type));
							reads[predecessor].push(fieldGet(body, read, current,
								IrInlineValueLayout.slotName(part, sub), where));
							current = read;
							break;
						}
						var read = body.newValue("$value-phi-read", body.typeId(field.type));
						reads[predecessor].push(fieldGet(body, read, current, part, where));
						current = read;
					}
					inputs[slotIndex].push(from);
					inputs[slotIndex].push(current);
				}
			}
			var scalar = [for (slot in shape) body.newValue("$value-phi-slot", body.typeId(slot.type))];
			body.beginRow();
			setups[target].push(body.endRow(IrOpcode.ValueInit, out, 0, where));
			for (index in 0...shape.length) {
				var current = out, path = shape[index].path;
				for (partIndex in 0...path.length) {
					var part = path[partIndex], field = declared(body.valueType(current), part);
					if (optionalValue(field)) {
						var slot = shape[index],
							sub:IrInlineValueSlot = {
								path: path.slice(partIndex + 1),
								type: slot.type,
								isPresence: slot.isPresence,
								nativeLayout: slot.nativeLayout
							};
						setups[target].push(fieldSet(body, current, IrInlineValueLayout.slotName(part, sub),
							scalar[index], where));
						break;
					}
					if (partIndex == path.length - 1)
						setups[target].push(fieldSet(body, current, part, scalar[index], where));
					else {
						var child = body.newValue("$value-phi-child", body.typeId(field.type));
						setups[target].push(fieldGet(body, child, current, part, where));
						current = child;
					}
				}
			}
			for (index in 0...shape.length) {
				var entries = inputs[index];
				body.beginRow();
				for (entry in 0...Std.int(entries.length / 2))
					body.pushOperand(IrValueId.of(entries[entry * 2 + 1]));
				var start = 0;
				for (entry in 0...Std.int(entries.length / 2)) {
					var at = body.pushInt(entries[entry * 2]);
					if (entry == 0)
						start = at;
				}
				phis[target].push(body.endRow(IrOpcode.Phi, scalar[index], start, where));
			}
			removed.push(row);
		}
		// Each block: its other phis, the scalar phis, the values made again, its other rows, then the reads for its successors.
		for (block in 0...count) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var next = body.nextRow(row);
				if (removed.indexOf(row) >= 0)
					body.removeRow(block, row);
				row = next;
			}
			var after = -1;
			row = body.firstRow(block);
			while (row >= 0 && body.opcode(row) == IrOpcode.Phi) {
				after = row;
				row = body.nextRow(row);
			}
			for (made in phis[block]) {
				body.linkAfter(block, after, made);
				after = made;
			}
			for (made in setups[block]) {
				body.linkAfter(block, after, made);
				after = made;
			}
			var terminator = body.terminatorRow(block);
			for (made in reads[block])
				body.linkBefore(block, terminator, made);
		}
	}

	function fieldSet(body:IrBody, owner:IrValueId, field:String, value:IrValueId, provenance:SourceProvenance):Int {
		body.beginRow();
		body.pushOperand(owner);
		body.pushOperand(value);
		return body.endRow(IrOpcode.FieldSet, IrValueId.of(-1), IrSymbol.of(field).id, provenance);
	}
}
