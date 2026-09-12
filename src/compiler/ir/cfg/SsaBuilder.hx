package compiler.ir.cfg;

import compiler.ir.cfg.Cfg;
import compiler.ir.cfg.CfgVerifier;
import compiler.ir.Ir;
import compiler.ir.SourceProvenance;
import compiler.ir.SourceProvenance.Located;
import compiler.ir.SourceProvenance.SourceOrigin;

/** Pending phi definition populated while mutable locals are renamed. */
private typedef SsaPhi = {output:IrValue, inputs:Array<IrPhiInput>};

private typedef SsaDefinitionBlocks = {blocks:Array<Int>, contains:Map<Int, Bool>};

/** Constructs minimal SSA with dominance frontiers, then renames mutable locals. */
class SsaBuilder {
	var cfg:CfgFunction;
	var output:Array<IrBlock>;
	var predecessors:Array<Array<Int>> = [];
	var successors:Array<Array<Int>> = [];
	var reachable:Array<Bool> = [];
	var immediate:Array<Int> = [];
	var children:Array<Array<Int>> = [];
	var frontiers:Array<Map<Int, Bool>> = [];
	var frontierKeys:Array<Array<Int>> = [];
	var liveIn:Array<Map<String, Bool>> = [];
	var phis:Array<Map<String, SsaPhi>> = [];
	var phiNames:Array<Array<String>> = [];
	var roots:Array<Int> = [];
	var stacks:Map<String, Array<IrValue>> = [];
	var temporaries:Array<Null<IrValue>> = [];
	var nextValue:Int = 0;
	var renamed:Array<Bool> = [];
	var debugBindings:Array<compiler.ir.IrFunction.IrDebugBinding> = [];
	var debugLocals:Map<String, compiler.ir.cfg.Cfg.CfgDebugLocal> = [];

	public static function build(cfg:CfgFunction):IrFunction {
		CfgVerifier.verify(cfg);
		return new SsaBuilder(cfg).run();
	}

	function new(cfg) {
		this.cfg = cfg;
		for (local in cfg.debugLocals)
			if (!debugLocals.exists(local.identity))
				debugLocals.set(local.identity, local);
	}

	function run():IrFunction {
		output = [for (block in cfg.blocks) new IrBlock(block.id)];
		predecessors = [for (_ in cfg.blocks) []];
		successors = [for (_ in cfg.blocks) []];
		reachable = [for (_ in cfg.blocks) false];
		immediate = [for (_ in cfg.blocks) -1];
		children = [for (_ in cfg.blocks) []];
		frontiers = [for (_ in cfg.blocks) []];
		frontierKeys = [for (_ in cfg.blocks) []];
		liveIn = [for (_ in cfg.blocks) []];
		phis = [for (_ in cfg.blocks) []];
		phiNames = [for (_ in cfg.blocks) []];
		renamed = [for (_ in cfg.blocks) false];
		temporaries = [for (_ in 0...cfg.valueCount) null];
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
			addDebugBinding(debugLocal(argument.name), value);
		}
		var orderedRoots = roots.copy();
		orderedRoots.sort(function(a, b) return a - b);
		for (root in orderedRoots)
			rename(root);
		for (block in cfg.blocks)
			if (reachable[block.id] && roots.indexOf(block.id) < 0 && immediate[block.id] == -1)
				rename(block.id);
		return new IrFunction(cfg.name, arguments, cfg.result, output, debugBindings);
	}

	function buildGraph():Void {
		roots = [0];
		var work = [0];
		while (work.length > 0) {
			var id = work.pop();
			if (id < 0 || id >= cfg.blocks.length)
				throw 'Unknown CFG block $id';
			if (reachable[id])
				continue;
			reachable[id] = true;
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
			successors[id] = next;
			for (target in next) {
				predecessors[target].push(id);
				work.push(target);
			}
		}
	}

	function computeDominators():Void {
		var visited:Array<Bool> = [for (_ in cfg.blocks) false],
			postorder:Array<Int> = [];
		for (root in roots)
			dominancePostorder(root, visited, postorder);
		postorder.reverse();
		var order:Array<Int> = [for (_ in cfg.blocks) -1];
		for (index in 0...postorder.length)
			order[postorder[index]] = index;
		for (root in roots)
			immediate[root] = root;
		var changed = true;
		while (changed) {
			changed = false;
			for (index in 1...postorder.length) {
				var id = postorder[index];
				if (predecessors[id].length == 0)
					throw 'Reachable SSA block $id has no predecessor or handler root';
				var next = -1;
				for (predecessor in predecessors[id])
					if (immediate[predecessor] >= 0)
						next = next < 0 ? predecessor : intersectDominators(predecessor, next, immediate, order);
				if (next >= 0 && immediate[id] != next) {
					immediate[id] = next;
					changed = true;
				}
			}
		}
		for (id in postorder)
			if (roots.indexOf(id) < 0) {
				if (immediate[id] < 0)
					throw 'Reachable SSA block $id has no immediate dominator';
				children[immediate[id]].push(id);
			}
		for (nested in children)
			nested.sort(function(a, b) return a - b);
	}

	function dominancePostorder(id:Int, visited:Array<Bool>, result:Array<Int>):Void {
		if (visited[id])
			return;
		visited[id] = true;
		for (successor in successors[id])
			dominancePostorder(successor, visited, result);
		result.push(id);
	}

	static function intersectDominators(left:Int, right:Int, immediate:Array<Int>, order:Array<Int>):Int {
		while (left != right) {
			while (order[left] > order[right])
				left = immediate[left];
			while (order[right] > order[left])
				right = immediate[right];
		}
		return left;
	}

	function computeFrontiers():Void {
		for (block in cfg.blocks)
			if (reachable[block.id])
				frontiers[block.id] = [];
		for (cfgBlock in cfg.blocks) {
			var block = cfgBlock.id;
			if (!reachable[block])
				continue;
			var preds = predecessors[block];
			if (preds.length < 2)
				continue;
			for (pred in preds) {
				var runner = pred;
				while (runner != immediate[block]) {
					if (!frontiers[runner].exists(block)) {
						frontiers[runner].set(block, true);
						frontierKeys[runner].push(block);
					}
					if (runner == 0 || roots.indexOf(runner) >= 0)
						break;
					if (immediate[runner] < 0)
						break;
					runner = immediate[runner];
				}
			}
		}
	}

	function computeLiveness():Void {
		var uses:Array<Map<String, Bool>> = [for (_ in cfg.blocks) []],
			defs:Array<Map<String, Bool>> = [for (_ in cfg.blocks) []],
			liveOut:Array<Map<String, Bool>> = [for (_ in cfg.blocks) []];
		for (block in cfg.blocks) {
			var id = block.id;
			if (!reachable[id])
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
			uses[id] = use;
			defs[id] = def;
			liveIn[id] = [];
			liveOut[id] = [];
		}
		var work:Array<Int> = [],
			queued:Array<Bool> = [for (_ in cfg.blocks) false];
		for (block in cfg.blocks)
			if (reachable[block.id]) {
				work.push(block.id);
				queued[block.id] = true;
			}
		while (work.length > 0) {
			var id = work.pop();
			queued[id] = false;
			var out = liveOut[id];
			for (successor in successors[id])
				for (name in liveIn[successor].keys())
					if (!out.exists(name))
						out.set(name, true);
			var input = liveIn[id], changed = false;
			for (name in uses[id].keys())
				if (!input.exists(name)) {
					input.set(name, true);
					changed = true;
				}
			for (name in out.keys())
				if (!defs[id].exists(name) && !input.exists(name)) {
					input.set(name, true);
					changed = true;
				}
			if (changed) {
				for (predecessor in predecessors[id])
					if (!queued[predecessor]) {
						queued[predecessor] = true;
						work.push(predecessor);
					}
			}
		}
	}

	function insertPhis():Void {
		var definitions:Map<String, SsaDefinitionBlocks> = [],
			definitionNames:Array<String> = [];
		for (argument in cfg.arguments)
			addDefinition(definitions, definitionNames, argument.name, 0);
		for (block in cfg.blocks)
			if (reachable[block.id])
				for (located in block.instructions)
					switch located.value {
						case StoreLocal(name, _):
							addDefinition(definitions, definitionNames, name, block.id);
						default:
					}
		for (name in definitionNames) {
			var definitionBlocks = definitions.get(name);
			if (definitionBlocks == null)
				throw 'Missing SSA definitions for local "$name"';
			var work = definitionBlocks.blocks.copy(),
				placed:Map<Int, Bool> = [];
			var cursor = 0;
			while (cursor < work.length) {
				var block = work[cursor++];
				for (join in frontierKeys[block])
					if (!placed.exists(join) && liveIn[join].exists(name)) {
						placed.set(join, true);
						phis[join].set(name, {output: allocate(name, cfg.localTypes.get(name)), inputs: []});
						phiNames[join].push(name);
						if (!definitionBlocks.contains.exists(join))
							work.push(join);
					}
			}
		}
	}

	function rename(id:Int):Void {
		if (renamed[id])
			return;
		renamed[id] = true;
		var block = cfg.blocks[id],
			target = output[id],
			pushed:Array<String> = [];
		if (phiNames[id].length > 0) {
			var blockPhis = phis[id];
			for (name in phiNames[id]) {
				if (!blockPhis.exists(name))
					throw 'Missing SSA phi "$name" for block $id';
				var phi = blockPhis.get(name);
				target.instructions.push(new Located(Phi(phi.output, phi.inputs), phiProvenance(id)));
				addDebugBinding(debugLocal(name), phi.output);
				push(name, phi.output);
				pushed.push(name);
			}
		}
		for (located in block.instructions) {
			var provenance = located.provenance;
			switch located.value {
				case LoadLocal(out, name):
					var id:Int = out.id;
					temporaries[id] = current(name);
				case StoreLocal(name, value):
					var resolved = resolve(value);
					push(name, resolved);
					addDebugBinding(debugLocal(name), resolved);
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
				case IntToFloat(out, value):
					var result = define(out);
					emit(target, IntToFloat(result, resolve(value)), provenance);
				case IntToInt64(out, value):
					var result = define(out);
					emit(target, IntToInt64(result, resolve(value)), provenance);
				case FloatToInt(out, value):
					var result = define(out);
					emit(target, FloatToInt(result, resolve(value)), provenance);
				case SafeCast(out, value):
					var result = define(out);
					emit(target, SafeCast(result, resolve(value)), provenance);
				case BeginTry(catchBlock, afterBlock):
					emit(target, BeginTry(catchBlock, afterBlock), provenance);
				case EndTry(catchBlock):
					emit(target, EndTry(catchBlock), provenance);
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
				case CNativeCall(out, name, args):
					var result = define(out);
					emit(target, CNativeCall(result, name, [for (arg in args) resolve(arg)]), provenance);
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
				case IteratorNew(out, array):
					var result = define(out);
					emit(target, IteratorNew(result, resolve(array)), provenance);
				case IteratorHasNext(out, iterator):
					var result = define(out);
					emit(target, IteratorHasNext(result, resolve(iterator)), provenance);
				case IteratorNext(out, iterator):
					var result = define(out);
					emit(target, IteratorNext(result, resolve(iterator)), provenance);
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
		for (successor in successors[id])
			if (phiNames[successor].length > 0) {
				var successorPhis = phis[successor];
				for (name in phiNames[successor]) {
					if (!successorPhis.exists(name))
						throw 'Missing SSA phi "$name" for successor block $successor';
					var phi = successorPhis.get(name);
					var inputs = phi.inputs;
					inputs.push({block: id, value: current(name)});
				}
			}
		for (child in children[id])
			rename(child);
		var pushedIndex = pushed.length;
		while (pushedIndex > 0) {
			pushedIndex--;
			stacks.get(pushed[pushedIndex]).pop();
		}
	}

	function define(value:CfgValue):IrValue {
		var id:Int = value.id;
		var result = allocate('v${value.id}', value.type);
		temporaries[id] = result;
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
		var id:Int = value.id;
		if (id < 0 || id >= temporaries.length)
			throw 'CFG value ${value.id} used before definition';
		var resolved = temporaries[id];
		if (resolved == null)
			throw 'CFG value ${value.id} used before definition';
		return resolved;
	}

	function allocate(name:String, type:IrType):IrValue {
		return new IrValue(nextValue++, name, type);
	}

	function debugLocal(identity:String):Null<compiler.ir.cfg.Cfg.CfgDebugLocal>
		return debugLocals.get(identity);

	function addDebugBinding(local:Null<compiler.ir.cfg.Cfg.CfgDebugLocal>, value:IrValue):Void {
		if (local != null)
			debugBindings.push({
				identity: local.identity,
				name: local.name,
				value: value,
				path: local.span.file.path,
				scopeStart: local.span.start,
				scopeEnd: local.scopeEnd
			});
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

	function addDefinition(map:Map<String, SsaDefinitionBlocks>, names:Array<String>, name:String, id:Int):Void {
		var found = map.get(name);
		if (found == null) {
			found = {blocks: [], contains: []};
			map.set(name, found);
			names.push(name);
		}
		if (!found.contains.exists(id)) {
			found.contains.set(id, true);
			found.blocks.push(id);
		}
	}
}
