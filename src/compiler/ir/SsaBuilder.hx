package compiler.ir;

import compiler.ir.Cfg;
import compiler.ir.Ir;

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
	var phis:Map<Int, Map<String, {output:IrValue, inputs:Array<IrPhiInput>}>> = [];
	var roots:Array<Int> = [];
	var stacks:Map<String, Array<IrValue>> = [];
	var temporaries:Map<Int, IrValue> = [];
	var nextValue:Int = 0;
	var renamed:Map<Int, Bool> = [];

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
		return new IrFunction(cfg.name, arguments, cfg.result, output);
	}

	function buildGraph():Void {
		roots = [0];
		var work = [0];
		while (work.length > 0) {
			var id = work.pop();
			if (reachable.exists(id))
				continue;
			reachable.set(id, true);
			var block = cfg.blocks[id];
			if (block == null)
				throw 'Unknown CFG block $id';
			for (instruction in block.instructions)
				switch instruction {
					case BeginTry(catchBlock):
						if (roots.indexOf(catchBlock) < 0)
							roots.push(catchBlock);
						work.push(catchBlock);
					default:
				}
			var next:Array<Int> = switch block.terminator {
				case Jump(target): [target];
				case Branch(_, yes, no): [yes, no];
				case Return(_), Throw(_): [];
				case null: throw 'Reachable CFG block $id has no terminator';
			};
			successors.set(id, next);
			for (target in next) {
				var found = predecessors.get(target);
				if (found == null) {
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
					var preds = predecessors.get(id);
					if (preds == null || preds.length == 0)
						throw 'Reachable SSA block $id has no predecessor or handler root';
					var next:Map<Int, Bool> = null;
					for (pred in preds)
						next = next == null ? copySet(dominators.get(pred)) : intersect(next, dominators.get(pred));
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
				var list = children.get(best);
				if (list == null) {
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
			var preds = predecessors.get(block);
			if (preds == null || preds.length < 2)
				continue;
			for (pred in preds) {
				var runner = pred;
				while (runner != immediate.get(block)) {
					var frontier = frontiers.get(runner);
					if (frontier != null)
						frontier.set(block, true);
					if (runner == 0 || roots.indexOf(runner) >= 0)
						break;
					var next = immediate.get(runner);
					if (next == null)
						break;
					runner = next;
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
			for (instruction in cfg.blocks[id].instructions)
				switch instruction {
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
				var out:Map<String, Bool> = [], next = successors.get(id);
				if (next != null)
					for (successor in next)
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
				for (instruction in block.instructions)
					switch instruction {
						case StoreLocal(name, _):
							addDefinition(definitions, name, block.id);
						default:
					}
		for (name in sortedStringKeys(definitions)) {
			var blocks = definitions.get(name),
				work = sortedIntKeys(blocks),
				placed:Map<Int, Bool> = [];
			while (work.length > 0) {
				var block = work.shift();
				for (join in sortedIntKeys(frontiers.get(block)))
					if (!placed.exists(join) && liveIn.get(join).exists(name)) {
						placed.set(join, true);
						var map = phis.get(join);
						if (map == null) {
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
		var blockPhis = phis.get(id);
		if (blockPhis != null)
			for (name in sortedStringKeys(blockPhis)) {
				var phi = blockPhis.get(name);
				target.instructions.push(Phi(phi.output, phi.inputs));
				push(name, phi.output);
				pushed.push(name);
			}
		for (instruction in block.instructions)
			switch instruction {
				case LoadLocal(out, name):
					temporaries.set(out.id, current(name));
				case StoreLocal(name, value):
					push(name, resolve(value));
					pushed.push(name);
				case ConstVoid(out):
					var result = define(out);
					target.instructions.push(ConstVoid(result));
				case ConstInt(out, value):
					var result = define(out);
					target.instructions.push(ConstInt(result, value));
				case ConstFloat(out, value):
					var result = define(out);
					target.instructions.push(ConstFloat(result, value));
				case ConstString(out, value):
					var result = define(out);
					target.instructions.push(ConstString(result, value));
				case ConstBool(out, value):
					var result = define(out);
					target.instructions.push(ConstBool(result, value));
				case ConstNull(out):
					var result = define(out);
					target.instructions.push(ConstNull(result));
				case ToDyn(out, value):
					var result = define(out);
					target.instructions.push(ToDyn(result, resolve(value)));
				case BeginTry(catchBlock):
					target.instructions.push(BeginTry(catchBlock));
				case EndTry:
					target.instructions.push(EndTry);
				case Catch(out):
					var result = define(out);
					target.instructions.push(Catch(result));
				case GlobalGet(out, name):
					var result = define(out);
					target.instructions.push(GlobalGet(result, name));
				case GlobalSet(name, value):
					target.instructions.push(GlobalSet(name, resolve(value)));
				case Add(out, a, b):
					var result = define(out);
					target.instructions.push(Add(result, resolve(a), resolve(b)));
				case Sub(out, a, b):
					var result = define(out);
					target.instructions.push(Sub(result, resolve(a), resolve(b)));
				case Mul(out, a, b):
					var result = define(out);
					target.instructions.push(Mul(result, resolve(a), resolve(b)));
				case Div(out, a, b):
					var result = define(out);
					target.instructions.push(Div(result, resolve(a), resolve(b)));
				case Mod(out, a, b):
					var result = define(out);
					target.instructions.push(Mod(result, resolve(a), resolve(b)));
				case Less(out, a, b):
					var result = define(out);
					target.instructions.push(Less(result, resolve(a), resolve(b)));
				case LessEqual(out, a, b):
					var result = define(out);
					target.instructions.push(LessEqual(result, resolve(a), resolve(b)));
				case Equal(out, a, b):
					var result = define(out);
					target.instructions.push(Equal(result, resolve(a), resolve(b)));
				case Call(out, name, args):
					var result = define(out);
					target.instructions.push(Call(result, name, [for (arg in args) resolve(arg)]));
				case StaticClosure(out, name):
					var result = define(out);
					target.instructions.push(StaticClosure(result, name));
				case InstanceClosure(out, name, receiver):
					var result = define(out);
					target.instructions.push(InstanceClosure(result, name, resolve(receiver)));
				case CallClosure(out, closure, args):
					var result = define(out);
					target.instructions.push(CallClosure(result, resolve(closure), [for (arg in args) resolve(arg)]));
				case ToVirtual(out, value):
					var result = define(out);
					target.instructions.push(ToVirtual(result, resolve(value)));
				case MethodCall(out, object, methodName, args):
					var result = define(out);
					target.instructions.push(MethodCall(result, resolve(object), methodName, [for (arg in args) resolve(arg)]));
				case NewObject(out, typeName):
					var result = define(out);
					target.instructions.push(NewObject(result, typeName));
				case FieldGet(out, object, fieldName):
					var result = define(out);
					target.instructions.push(FieldGet(result, resolve(object), fieldName));
				case FieldSet(object, fieldName, value):
					target.instructions.push(FieldSet(resolve(object), fieldName, resolve(value)));
				case ArrayGet(out, array, index):
					var result = define(out);
					target.instructions.push(ArrayGet(result, resolve(array), resolve(index)));
				case ArraySet(array, index, value):
					target.instructions.push(ArraySet(resolve(array), resolve(index), resolve(value)));
				case ArraySize(out, array):
					var result = define(out);
					target.instructions.push(ArraySize(result, resolve(array)));
				case MakeEnum(out, typeName, constructor, arguments):
					var result = define(out);
					target.instructions.push(MakeEnum(result, typeName, constructor, [for (argument in arguments) resolve(argument)]));
				case EnumIndex(out, value):
					var result = define(out);
					target.instructions.push(EnumIndex(result, resolve(value)));
				case EnumField(out, value, constructor, field):
					var result = define(out);
					target.instructions.push(EnumField(result, resolve(value), constructor, field));
			}
		target.terminator = switch block.terminator {
			case Return(value): Return(resolve(value));
			case Throw(value): Throw(resolve(value));
			case Jump(to): Jump(to);
			case Branch(condition, yes, no): Branch(resolve(condition), yes, no);
			case null: null;
		};
		var next = successors.get(id);
		if (next != null)
			for (successor in next) {
				var successorPhis = phis.get(successor);
				if (successorPhis != null)
					for (name in sortedStringKeys(successorPhis))
						successorPhis.get(name).inputs.push({block: id, value: current(name)});
			}
		var nested = children.get(id);
		if (nested != null) {
			nested.sort(function(a, b) return a - b);
			for (child in nested)
				rename(child);
		}
		pushed.reverse();
		for (name in pushed)
			stacks.get(name).pop();
	}

	function define(value:CfgValue):IrValue {
		var result = allocate('v${value.id}', value.type);
		temporaries.set(value.id, result);
		return result;
	}

	function resolve(value:CfgValue):IrValue {
		var result = temporaries.get(value.id);
		if (result == null)
			throw 'CFG value ${value.id} used before definition';
		return result;
	}

	function allocate(name:String, type:IrType):IrValue {
		if (type == null)
			throw 'Missing type for local "$name"';
		return new IrValue(nextValue++, name, type);
	}

	function push(name:String, value:IrValue):Void {
		var stack = stacks.get(name);
		if (stack == null) {
			stack = [];
			stacks.set(name, stack);
		}
		stack.push(value);
	}

	function current(name:String):IrValue {
		var stack = stacks.get(name);
		if (stack == null || stack.length == 0)
			throw 'Local "$name" used before definition';
		return stack[stack.length - 1];
	}

	function addDefinition(map:Map<String, Map<Int, Bool>>, name:String, id:Int):Void {
		var found = map.get(name);
		if (found == null) {
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

	static function sortedIntKeys<T>(map:Map<Int, T>):Array<Int> {
		var result = [for (id in map.keys()) id];
		result.sort(function(a, b) return a - b);
		return result;
	}

	static function sortedStringKeys<T>(map:Map<String, T>):Array<String> {
		var result = [for (name in map.keys()) name];
		result.sort(Reflect.compare);
		return result;
	}
}
