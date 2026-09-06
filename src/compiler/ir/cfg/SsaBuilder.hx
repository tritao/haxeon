package compiler.ir.cfg;

import compiler.ir.cfg.Cfg;
import compiler.ir.cfg.CfgVerifier;
import compiler.ir.Ir;
import compiler.ir.SourceProvenance;
import compiler.ir.SourceProvenance.Located;
import compiler.ir.SourceProvenance.SourceOrigin;

/** Pending phi definition populated while mutable locals are renamed. */
private typedef SsaPhi = {output:IrValue, inputs:Array<IrPhiInput>};

/** Constructs minimal SSA with dominance frontiers, then renames mutable locals. */
class SsaBuilder {
	var cfg:CfgFunction;
	var output:Array<IrBlock>;
	var predecessors:Map<Int, Array<Int>> = [];
	var successors:Map<Int, Array<Int>> = [];
	var reachable:Map<Int, Bool> = [];
	var dominators:Map<Int, Map<Int, Bool>> = [];
	var immediate:Map<Int, Int> = [];
	var children:Map<Int, Array<Int>> = [];
	var frontiers:Map<Int, Map<Int, Bool>> = [];
	var liveIn:Map<Int, Map<String, Bool>> = [];
	var phis:Map<Int, Map<String, SsaPhi>> = [];
	var roots:Array<Int> = [];
	var stacks:Map<String, Array<IrValue>> = [];
	var temporaries:Map<Int, IrValue> = [];
	var nextValue:Int = 0;
	var renamed:Map<Int, Bool> = [];
	var debugBindings:Array<compiler.ir.IrFunction.IrDebugBinding> = [];

	public static function build(cfg:CfgFunction):IrFunction {
		CfgVerifier.verify(cfg);
		return new SsaBuilder(cfg).run();
	}

	function new(cfg)
		this.cfg = cfg;

	function run():IrFunction {
		output = [for (block in cfg.blocks) new IrBlock(block.id)];
		buildGraph();
		computeDominators();
		computeFrontiers();
		computeLiveness();
		insertPhis();
		var arguments:Array<IrValue> = [];
		for (argument in cfg.arguments) {
			var value = allocate(argument.name, argument.type);
			arguments.push(value);
			push(argument.name, value);
		}
		var orderedRoots = roots.copy();
		orderedRoots.sort(function(a, b) return a - b);
		for (root in orderedRoots)
			rename(root);
		for (block in cfg.blocks)
			if (reachable.exists(block.id) && roots.indexOf(block.id) < 0 && immediate.exists(block.id) && immediate.get(block.id) == -1)
				rename(block.id);
		return new IrFunction(cfg.name, arguments, cfg.result, output, debugBindings);
	}

	function buildGraph():Void {
		roots = [0];
		var work = [0];
		while (work.length > 0) {
			var id = work.pop();
			if (reachable.exists(id))
				continue;
			reachable.set(id, true);
			if (id < 0 || id >= cfg.blocks.length)
				throw 'Unknown CFG block $id';
			var block = cfg.blocks[id];
			var handlers:Array<Int> = [];
			for (located in block.instructions)
				switch located.value {
					case BeginTry(catchBlock, _):
						handlers.push(catchBlock);
					default:
				}
			var terminator = block.terminator;
			if (terminator == null)
				throw 'Reachable CFG block $id has no terminator';
			var next:Array<Int> = switch terminator.value {
				case Jump(target): [target];
				case Branch(_, yes, no): [yes, no];
				case Return(_), Throw(_), Rethrow(_): [];
			};
			for (handler in handlers)
				if (next.indexOf(handler) < 0)
					next.push(handler);
			successors.set(id, next);
			for (target in next) {
				var found:Array<Int>;
				if (predecessors.exists(target))
					found = predecessors.get(target);
				else {
					found = [];
					predecessors.set(target, found);
				}
				found.push(id);
				work.push(target);
			}
		}
	}

	function computeDominators():Void {
		var all:Map<Int, Bool> = [];
		for (block in cfg.blocks)
			if (reachable.exists(block.id))
				all.set(block.id, true);
		for (block in cfg.blocks)
			if (reachable.exists(block.id))
				dominators.set(block.id, roots.indexOf(block.id) >= 0 ? singleton(block.id) : copySet(all));
		var changed = true;
		while (changed) {
			changed = false;
			for (block in cfg.blocks) {
				var id = block.id;
				if (reachable.exists(id) && roots.indexOf(id) < 0) {
					if (!predecessors.exists(id))
						throw 'Reachable SSA block $id has no predecessor or handler root';
					var preds = predecessors.get(id);
					if (preds.length == 0)
						throw 'Reachable SSA block $id has no predecessor or handler root';
					var next = copySet(dominators.get(preds[0]));
					for (index in 1...preds.length)
						next = intersect(next, dominators.get(preds[index]));
					next.set(id, true);
					if (!sameSet(next, dominators.get(id))) {
						dominators.set(id, next);
						changed = true;
					}
				}
			}
		}
		for (block in cfg.blocks) {
			var id = block.id;
			if (reachable.exists(id) && roots.indexOf(id) < 0) {
				var best = -1, bestDepth = -1;
				for (candidate in sortedIntKeys(dominators.get(id)))
					if (candidate != id) {
						var depth = count(dominators.get(candidate));
						if (depth > bestDepth) {
							best = candidate;
							bestDepth = depth;
						}
					}
				immediate.set(id, best);
				var list:Array<Int>;
				if (children.exists(best))
					list = children.get(best);
				else {
					list = [];
					children.set(best, list);
				}
				list.push(id);
			}
		}
	}

	function computeFrontiers():Void {
		for (block in cfg.blocks)
			if (reachable.exists(block.id))
				frontiers.set(block.id, []);
		for (cfgBlock in cfg.blocks) {
			var block = cfgBlock.id;
			if (!reachable.exists(block))
				continue;
			if (!predecessors.exists(block))
				continue;
			var preds = predecessors.get(block);
			if (preds.length < 2)
				continue;
			for (pred in preds) {
				var runner = pred;
				while (runner != immediate.get(block)) {
					if (frontiers.exists(runner))
						frontiers.get(runner).set(block, true);
					if (runner == 0 || roots.indexOf(runner) >= 0)
						break;
					if (!immediate.exists(runner))
						break;
					runner = immediate.get(runner);
				}
			}
		}
	}

	function computeLiveness():Void {
		var uses:Map<Int, Map<String, Bool>> = [],
			defs:Map<Int, Map<String, Bool>> = [],
			liveOut:Map<Int, Map<String, Bool>> = [];
		for (block in cfg.blocks) {
			var id = block.id;
			if (!reachable.exists(id))
				continue;
			var use:Map<String, Bool> = [], def:Map<String, Bool> = [];
			for (located in cfg.blocks[id].instructions)
				switch located.value {
					case LoadLocal(_, name):
						if (!def.exists(name))
							use.set(name, true);
					case StoreLocal(name, _):
						def.set(name, true);
					default:
				}
			uses.set(id, use);
			defs.set(id, def);
			liveIn.set(id, []);
			liveOut.set(id, []);
		}
		var changed = true;
		while (changed) {
			changed = false;
			for (block in cfg.blocks) {
				var id = block.id;
				if (!reachable.exists(id))
					continue;
				var out:Map<String, Bool> = [];
				if (successors.exists(id))
					for (successor in successors.get(id))
						for (name in liveIn.get(successor).keys())
							out.set(name, true);
				var input = copyNames(uses.get(id));
				for (name in out.keys())
					if (!defs.get(id).exists(name))
						input.set(name, true);
				if (!sameNames(out, liveOut.get(id)) || !sameNames(input, liveIn.get(id))) {
					liveOut.set(id, out);
					liveIn.set(id, input);
					changed = true;
				}
			}
		}
	}

	function insertPhis():Void {
		var definitions:Map<String, Map<Int, Bool>> = [];
		for (argument in cfg.arguments)
			addDefinition(definitions, argument.name, 0);
		for (block in cfg.blocks)
			if (reachable.exists(block.id))
				for (located in block.instructions)
					switch located.value {
						case StoreLocal(name, _):
							addDefinition(definitions, name, block.id);
						default:
					}
		for (name in sortedDefinitionNames(definitions)) {
			var blocks = definitions.get(name),
				work = sortedIntKeys(blocks),
				placed:Map<Int, Bool> = [];
			var cursor = 0;
			while (cursor < work.length) {
				var block = work[cursor++];
				for (join in sortedIntKeys(frontiers.get(block)))
					if (!placed.exists(join) && liveIn.get(join).exists(name)) {
						placed.set(join, true);
						var map:Map<String, SsaPhi>;
						if (phis.exists(join))
							map = phis.get(join);
						else {
							map = [];
							phis.set(join, map);
						}
						map.set(name, {output: allocate(name, cfg.localTypes.get(name)), inputs: []});
						if (!blocks.exists(join))
							work.push(join);
					}
			}
		}
	}

	function rename(id:Int):Void {
		if (renamed.exists(id))
			return;
		renamed.set(id, true);
		var block = cfg.blocks[id],
			target = output[id],
			pushed:Array<String> = [];
		if (phis.exists(id)) {
			var blockPhis = phis.get(id);
			for (name in sortedPhiNames(blockPhis)) {
				var phi = blockPhis.get(name);
				target.instructions.push(new Located(Phi(phi.output, phi.inputs), phiProvenance(id)));
				push(name, phi.output);
				pushed.push(name);
			}
		}
		for (located in block.instructions) {
			var provenance = located.provenance;
			switch located.value {
				case LoadLocal(out, name):
					temporaries.set(out.id, current(name));
				case StoreLocal(name, value):
					var resolved = resolve(value);
					push(name, resolved);
					var debugName = sourceDebugName(name);
					if (debugName != null)
						debugBindings.push({name: debugName, value: resolved});
					pushed.push(name);
				case ConstVoid(out):
					var result = define(out);
					emit(target, ConstVoid(result), provenance);
				case ConstInt(out, value):
					var result = define(out);
					emit(target, ConstInt(result, value), provenance);
				case ConstFloat(out, value):
					var result = define(out);
					emit(target, ConstFloat(result, value), provenance);
				case ConstString(out, value):
					var result = define(out);
					emit(target, ConstString(result, value), provenance);
				case ConstBool(out, value):
					var result = define(out);
					emit(target, ConstBool(result, value), provenance);
				case ConstNull(out):
					var result = define(out);
					emit(target, ConstNull(result), provenance);
				case TypeValue(out, type):
					var result = define(out);
					emit(target, TypeValue(result, type), provenance);
				case ToDyn(out, value):
					var result = define(out);
					emit(target, ToDyn(result, resolve(value)), provenance);
				case SafeCast(out, value):
					var result = define(out);
					emit(target, SafeCast(result, resolve(value)), provenance);
				case BeginTry(catchBlock, afterBlock):
					emit(target, BeginTry(catchBlock, afterBlock), provenance);
				case EndTry:
					emit(target, EndTry, provenance);
				case Catch(out):
					var result = define(out);
					emit(target, Catch(result), provenance);
				case GlobalGet(out, name):
					var result = define(out);
					emit(target, GlobalGet(result, name), provenance);
				case GlobalSet(name, value):
					emit(target, GlobalSet(name, resolve(value)), provenance);
				case Add(out, a, b):
					var result = define(out);
					emit(target, Add(result, resolve(a), resolve(b)), provenance);
				case Sub(out, a, b):
					var result = define(out);
					emit(target, Sub(result, resolve(a), resolve(b)), provenance);
				case Mul(out, a, b):
					var result = define(out);
					emit(target, Mul(result, resolve(a), resolve(b)), provenance);
				case Div(out, a, b):
					var result = define(out);
					emit(target, Div(result, resolve(a), resolve(b)), provenance);
				case Mod(out, a, b):
					var result = define(out);
					emit(target, Mod(result, resolve(a), resolve(b)), provenance);
				case BitAnd(out, a, b):
					var result = define(out);
					emit(target, BitAnd(result, resolve(a), resolve(b)), provenance);
				case BitXor(out, a, b):
					var result = define(out);
					emit(target, BitXor(result, resolve(a), resolve(b)), provenance);
				case BitOr(out, a, b):
					var result = define(out);
					emit(target, BitOr(result, resolve(a), resolve(b)), provenance);
				case ShiftLeft(out, a, b):
					var result = define(out);
					emit(target, ShiftLeft(result, resolve(a), resolve(b)), provenance);
				case ShiftRight(out, a, b):
					var result = define(out);
					emit(target, ShiftRight(result, resolve(a), resolve(b)), provenance);
				case UnsignedShiftRight(out, a, b):
					var result = define(out);
					emit(target, UnsignedShiftRight(result, resolve(a), resolve(b)), provenance);
				case Less(out, a, b):
					var result = define(out);
					emit(target, Less(result, resolve(a), resolve(b)), provenance);
				case LessEqual(out, a, b):
					var result = define(out);
					emit(target, LessEqual(result, resolve(a), resolve(b)), provenance);
				case Equal(out, a, b):
					var result = define(out);
					emit(target, Equal(result, resolve(a), resolve(b)), provenance);
				case Call(out, name, args):
					var result = define(out);
					emit(target, Call(result, name, [for (arg in args) resolve(arg)]), provenance);
				case StaticClosure(out, name):
					var result = define(out);
					emit(target, StaticClosure(result, name), provenance);
				case InstanceClosure(out, name, receiver):
					var result = define(out);
					emit(target, InstanceClosure(result, name, resolve(receiver)), provenance);
				case CallClosure(out, closure, args):
					var result = define(out);
					emit(target, CallClosure(result, resolve(closure), [for (arg in args) resolve(arg)]), provenance);
				case ToVirtual(out, value):
					var result = define(out);
					emit(target, ToVirtual(result, resolve(value)), provenance);
				case MethodCall(out, object, methodName, args):
					var result = define(out);
					emit(target, MethodCall(result, resolve(object), methodName, [for (arg in args) resolve(arg)]), provenance);
				case NewObject(out, typeName):
					var result = define(out);
					emit(target, NewObject(result, typeName), provenance);
				case FieldGet(out, object, fieldName):
					var result = define(out);
					emit(target, FieldGet(result, resolve(object), fieldName), provenance);
				case FieldSet(object, fieldName, value):
					emit(target, FieldSet(resolve(object), fieldName, resolve(value)), provenance);
				case ArrayGet(out, array, index):
					var result = define(out);
					emit(target, ArrayGet(result, resolve(array), resolve(index)), provenance);
				case ArraySet(array, index, value):
					emit(target, ArraySet(resolve(array), resolve(index), resolve(value)), provenance);
				case ArraySize(out, array):
					var result = define(out);
					emit(target, ArraySize(result, resolve(array)), provenance);
				case MakeEnum(out, typeName, constructor, arguments):
					var result = define(out);
					emit(target, MakeEnum(result, typeName, constructor, [for (argument in arguments) resolve(argument)]), provenance);
				case EnumIndex(out, value):
					var result = define(out);
					emit(target, EnumIndex(result, resolve(value)), provenance);
				case EnumField(out, value, constructor, field):
					var result = define(out);
					emit(target, EnumField(result, resolve(value), constructor, field), provenance);
			}
		}
		var terminator = block.terminator;
		if (terminator == null)
			throw 'Reachable CFG block $id has no terminator';
		target.terminator = new Located(switch terminator.value {
			case Return(value): Return(resolve(value));
			case Throw(value): Throw(resolve(value));
			case Rethrow(value): Rethrow(resolve(value));
			case Jump(to): Jump(to);
			case Branch(condition, yes, no): Branch(resolve(condition), yes, no);
		}, terminator.provenance);
		if (successors.exists(id))
			for (successor in successors.get(id)) {
				if (phis.exists(successor)) {
					var successorPhis = phis.get(successor);
					for (name in sortedPhiNames(successorPhis)) {
						var phi = successorPhis.get(name);
						var inputs = phi.inputs;
						inputs.push({block: id, value: current(name)});
					}
				}
			}
		if (children.exists(id)) {
			var nested = children.get(id);
			nested.sort(function(a, b) return a - b);
			for (child in nested)
				rename(child);
		}
		var pushedIndex = pushed.length;
		while (pushedIndex > 0) {
			pushedIndex--;
			stacks.get(pushed[pushedIndex]).pop();
		}
	}

	function define(value:CfgValue):IrValue {
		var result = allocate('v${value.id}', value.type);
		temporaries.set(value.id, result);
		return result;
	}

	static function emit(block:IrBlock, instruction:IrInstruction, provenance:SourceProvenance):Void
		block.instructions.push(new Located(instruction, provenance));

	function phiProvenance(blockId:Int):SourceProvenance {
		var block = cfg.blocks[blockId],
			anchor:Null<compiler.ir.SourceProvenance.SourceLocation> = null;
		if (block.instructions.length > 0)
			anchor = block.instructions[0].provenance.location;
		else if (block.terminator != null)
			anchor = block.terminator.provenance.location;
		return new SourceProvenance(anchor, SourceOrigin.CompilerGenerated("ssa-phi"));
	}

	function resolve(value:CfgValue):IrValue {
		if (!temporaries.exists(value.id))
			throw 'CFG value ${value.id} used before definition';
		return temporaries.get(value.id);
	}

	function allocate(name:String, type:IrType):IrValue {
		return new IrValue(nextValue++, name, type);
	}

	static function sourceDebugName(name:String):Null<String> {
		if (StringTools.startsWith(name, "$l")) {
			var separator = name.indexOf(":");
			return separator < 0 ? null : name.substr(separator + 1);
		}
		return StringTools.startsWith(name, "$") ? null : name;
	}

	function push(name:String, value:IrValue):Void {
		var stack:Array<IrValue>;
		if (stacks.exists(name))
			stack = stacks.get(name);
		else {
			stack = [];
			stacks.set(name, stack);
		}
		stack.push(value);
	}

	function current(name:String):IrValue {
		if (!stacks.exists(name))
			throw 'Local "$name" used before definition';
		var stack = stacks.get(name);
		if (stack.length == 0)
			throw 'Local "$name" used before definition';
		return stack[stack.length - 1];
	}

	function addDefinition(map:Map<String, Map<Int, Bool>>, name:String, id:Int):Void {
		var found:Map<Int, Bool>;
		if (map.exists(name))
			found = map.get(name);
		else {
			found = [];
			map.set(name, found);
		}
		found.set(id, true);
	}

	static function singleton(id:Int):Map<Int, Bool> {
		var result:Map<Int, Bool> = [];
		result.set(id, true);
		return result;
	}

	static function copySet(source:Map<Int, Bool>):Map<Int, Bool> {
		var result:Map<Int, Bool> = [];
		for (id in source.keys())
			result.set(id, true);
		return result;
	}

	static function intersect(a:Map<Int, Bool>, b:Map<Int, Bool>):Map<Int, Bool> {
		var result:Map<Int, Bool> = [];
		for (id in a.keys())
			if (b.exists(id))
				result.set(id, true);
		return result;
	}

	static function sameSet(a:Map<Int, Bool>, b:Map<Int, Bool>):Bool {
		if (count(a) != count(b))
			return false;
		for (id in a.keys())
			if (!b.exists(id))
				return false;
		return true;
	}

	static function count(set:Map<Int, Bool>):Int {
		var result = 0;
		for (_ in set.keys())
			result++;
		return result;
	}

	static function copyNames(source:Map<String, Bool>):Map<String, Bool> {
		var result:Map<String, Bool> = [];
		for (name in source.keys())
			result.set(name, true);
		return result;
	}

	static function sameNames(a:Map<String, Bool>, b:Map<String, Bool>):Bool {
		var ac = 0, bc = 0;
		for (_ in a.keys())
			ac++;
		for (_ in b.keys())
			bc++;
		if (ac != bc)
			return false;
		for (name in a.keys())
			if (!b.exists(name))
				return false;
		return true;
	}

	static function sortedIntKeys(map:Map<Int, Bool>):Array<Int> {
		var result = [for (id in map.keys()) id];
		result.sort(function(a, b) return a - b);
		return result;
	}

	static function sortedDefinitionNames(map:Map<String, Map<Int, Bool>>):Array<String> {
		var result = [for (key in map.keys()) key];
		result.sort(Reflect.compare);
		return result;
	}

	static function sortedPhiNames(map:Map<String, SsaPhi>):Array<String> {
		var result = [for (name in map.keys()) name];
		result.sort(Reflect.compare);
		return result;
	}
}
