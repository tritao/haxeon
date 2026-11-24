package compiler.ir.analysis;

import compiler.ir.model.Ir;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrBodyBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrOpcode;

/**
 * Calls that can execute while evaluating a function, excluding callbacks only stored for later. Each function gives, from its body
 * alone, the closures it may store in a global or return (`IrInitCalls.stores`), which the whole program's globals and returns are
 * solved from; and, read only for a function the walk reaches or asks about, what it calls and where its closures and arguments
 * flow (`IrInitCalls.calls`). A session keeps both by version.
 */
@:nullSafety(Strict)
class IrInitializationCalls {
	/** What each function the walk of what initialization calls reads calls (`IrInitCalls.calls`). */
	@:processWide("a contribution memo's key, only ever read")
	public static final CALLS = new compiler.ir.reuse.IrStageMemo.IrContributionKey<IrInitCalls>("init-calls");

	/** What each function stores for the walk of what initialization calls (`IrInitCalls.stores`), for the static null checks. */
	@:processWide("a contribution memo's key, only ever read")
	public static final STORES = new compiler.ir.reuse.IrStageMemo.IrContributionKey<IrInitCalls>("init-stores");

	/** The program's functions, in program order, and the one of a name. */
	final functions:Array<IrFunction>;

	final find:String->Null<IrFunction>;
	final summaries:Map<String, IrInitCalls> = [];
	final detail:IrFunction->IrInitCalls;
	final objects:Map<String, IrObject>;

	/** The same objects as a list, for the walk over all of them. */
	final objectList:Array<IrObject>;

	/** By method name, the program's functions of that name, for a receiver that is no object; made when first asked. */
	var methods:Null<Map<String, Array<String>>> = null;

	final invoked:Map<String, Bool> = [];
	final resolvedMethods:Map<String, Array<String>> = [];
	final globals:Map<String, Array<String>> = [];
	final returns:Map<String, Array<String>> = [];

	/**
	 * The program from its functions, in program order, what each stores (`IrInitCalls.stores`; null for one that stores nothing
	 * the walk follows), how to find a function by name (`find`) and how to read what one calls (`detail`, `IrInitCalls.calls`),
	 * asked only for the functions the walk reaches or asks about.
	 */
	public function new(functions:Array<IrFunction>, stores:Array<Null<IrInitCalls>>, detail:IrFunction->IrInitCalls,
			find:String->Null<IrFunction>, ?objects:Array<IrObject>) {
		this.functions = functions;
		this.find = find;
		this.detail = detail;
		this.objects = objects == null ? [] : [for (object in objects) object.name => object];
		objectList = objects == null ? [] : objects;
		var relevant:Array<Int> = [], flows:Array<Array<IrInitFlow>> = [];
		for (index in 0...functions.length) {
			var stored = stores[index];
			if (stored != null && stored.relevant) {
				relevant.push(index);
				flows.push(stored.flows);
			}
		}
		var changed = true;
		while (changed) {
			changed = false;
			for (position in 0...relevant.length)
				for (flow in flows[position]) {
					var target = switch flow.kind {
						case IrInitFlow.GLOBAL_SET: globals;
						case IrInitFlow.RETURN: returns;
						case _: null;
					};
					if (target == null)
						continue;
					var stored = closures(flow.sources);
					if (stored != null
						&& merge(target,
						flow.kind == IrInitFlow.RETURN ? functions[relevant[position]].name : flow.name,
						stored))
						changed = true;
				}
		}
	}

	/** The functions that evaluating `root` can call, `root` included, among those `exists` says the program has. */
	public function reachable(root:String, exists:String->Bool):Map<String, Bool> {
		var reached:Map<String, Bool> = [], pending = [root];
		while (pending.length > 0) {
			var name = pending.pop();
			if (name == null)
				break;
			if (reached.exists(name) || !exists(name))
				continue;
			reached.set(name, true);
			for (callee in calls(name))
				pending.push(callee);
		}
		return reached;
	}

	static function merge(target:Map<String, Array<String>>, key:String, values:Array<String>):Bool {
		var merged = target.get(key);
		if (merged == null)
			target.set(key, merged = []);
		var changed = false;
		for (value in values)
			if (!merged.contains(value)) {
				merged.push(value);
				changed = true;
			}
		return changed;
	}

	/** The closures `sources` may be, as the globals and returns stand; null for none. */
	function closures(sources:Array<IrInitSource>):Null<Array<String>> {
		var found:Null<Array<String>> = null;
		inline function add(names:Null<Array<String>>):Void
			if (names != null && names.length > 0) {
				var list = found;
				if (list == null)
					found = list = [];
				for (name in names)
					if (!list.contains(name))
						list.push(name);
			}
		for (source in sources)
			switch source.kind {
				case IrInitSource.CLOSURE:
					add([source.name]);
				case IrInitSource.GLOBAL:
					add(globals.get(source.name));
				case IrInitSource.RETURNED:
					add(returns.get(source.name));
				case IrInitSource.METHOD_RETURNED:
					for (callee in methodTargets(source.owner, source.name))
						add(returns.get(callee));
				case _:
			}
		return found;
	}

	/** What the function named `name` calls and where its closures and arguments flow, or null when the program has none. */
	function summaryOf(name:String):Null<IrInitCalls> {
		var known = summaries.get(name);
		if (known != null)
			return known;
		var fn = find(name);
		if (fn == null)
			return null;
		var made = detail(fn);
		summaries.set(name, made);
		return made;
	}

	/** What evaluating the function named `name`, one of the program's, can call. */
	public function calls(name:String):Array<String> {
		var summary = summaryOf(name);
		if (summary == null)
			throw new compiler.core.InternalError('"$name" is not a function of the program');
		var result = summary.callees.copy();
		var index = 0;
		while (index < summary.methods.length) {
			for (callee in methodTargets(summary.methods[index], summary.methods[index + 1] ?? ""))
				result.push(callee);
			index += 2;
		}
		for (flow in summary.flows)
			switch flow.kind {
				case IrInitFlow.CLOSURE_CALL:
					var targets = closures(flow.sources);
					if (targets != null)
						result = result.concat(targets);
				case IrInitFlow.CALL_ARGUMENT:
					var targets = closures(flow.sources);
					if (targets != null && invokesArgument(flow.name, flow.index, []))
						result = result.concat(targets);
				case IrInitFlow.METHOD_ARGUMENT:
					var targets = closures(flow.sources);
					if (targets != null)
						for (callee in methodTargets(flow.owner, flow.name))
							if (invokesArgument(callee, flow.index, []))
								result = result.concat(targets);
				case _:
			}
		return result;
	}

	function methodTargets(owner:Null<String>, method:String):Array<String> {
		if (owner == null || !objects.exists(owner))
			return byMethod().get(method) ?? [];
		var key = owner + "." + method, known = resolvedMethods.get(key);
		if (known != null)
			return known;
		var result:Array<String> = [];
		for (object in objectList) {
			var current:Null<IrObject> = object, matches = false;
			while (current != null) {
				if (current.name == owner) {
					matches = true;
					break;
				}
				current = current.base == null ? null : objects.get(current.base);
			}
			if (!matches)
				continue;
			current = object;
			while (current != null) {
				var target:Null<String> = null;
				for (entry in current.methods)
					if (entry.name == method) {
						target = entry.functionName.name;
						break;
					}
				if (target != null) {
					if (!result.contains(target))
						result.push(target);
					break;
				}
				current = current.base == null ? null : objects.get(current.base);
			}
		}
		result.sort(Reflect.compare);
		resolvedMethods.set(key, result);
		return result;
	}

	function byMethod():Map<String, Array<String>> {
		var known = methods;
		if (known != null)
			return known;
		var made:Map<String, Array<String>> = [];
		for (fn in functions) {
			var name = fn.name, dot = name.lastIndexOf(".");
			if (dot < 0)
				continue;
			var method = name.substr(dot + 1), named = made.get(method);
			if (named == null)
				made.set(method, named = []);
			named.push(name);
		}
		methods = made;
		return made;
	}

	/** Whether the function `name` calls its argument `index`, itself or through the functions it passes it to. */
	function invokesArgument(name:String, index:Int, seen:Map<String, Bool>):Bool {
		var key = name + ":" + index, known = invoked.get(key);
		if (known != null)
			return known;
		var summary = summaryOf(name);
		if (summary == null || seen.exists(key))
			return false;
		if (index >= summary.arguments)
			return false;
		var root = !seen.keys().hasNext();
		seen.set(key, true);
		var found = false;
		for (flow in summary.flows) {
			if (!flow.carries(index))
				continue;
			switch flow.kind {
				case IrInitFlow.CLOSURE_CALL:
					found = true;
				case IrInitFlow.CALL_ARGUMENT:
					if (invokesArgument(flow.name, flow.index, seen))
						found = true;
				case IrInitFlow.METHOD_ARGUMENT:
					for (callee in methodTargets(flow.owner, flow.name))
						if (invokesArgument(callee, flow.index, seen))
							found = true;
				case _:
			}
		}
		// Each argument is explored once per search, even through recursive forwarding graphs.
		// Only root negatives are complete; a nested search may have skipped an active caller.
		if (found || root)
			invoked.set(key, found);
		return found;
	}
}

/**
 * Where a value of a function may come from, for the closures it may be (`IrInitializationCalls`): a closure made in place, a
 * global, a function's or a method's return, or the function's own argument.
 */
@:nullSafety(Strict)
class IrInitSource {
	public static inline final CLOSURE = 0;
	public static inline final GLOBAL = 1;
	public static inline final RETURNED = 2;
	public static inline final METHOD_RETURNED = 3;
	public static inline final ARGUMENT = 4;

	public final kind:Int;

	/** The closure's function, the global, the callee or the method; "" for an argument. */
	public final name:String;

	/** The object a method is called on, or null. */
	public final owner:Null<String>;

	/** The argument's index. */
	public final index:Int;

	public function new(kind:Int, name:String, owner:Null<String>, index:Int) {
		this.kind = kind;
		this.name = name;
		this.owner = owner;
		this.index = index;
	}

	public function toString():String
		return '$kind:$name:$owner:$index';
}

/** A place in a function where values with sources go (`IrInitSource`): a global, its return, a closure call or a call's argument. */
@:nullSafety(Strict)
class IrInitFlow {
	public static inline final GLOBAL_SET = 0;
	public static inline final RETURN = 1;
	public static inline final CLOSURE_CALL = 2;
	public static inline final CALL_ARGUMENT = 3;
	public static inline final METHOD_ARGUMENT = 4;

	public final kind:Int;

	/** The global, the callee or the method; "" for a return or a closure call. */
	public final name:String;

	/** The object a method is called on, or null. */
	public final owner:Null<String>;

	/** The callee's argument the value is passed as. */
	public final index:Int;

	public final sources:Array<IrInitSource>;

	public function new(kind:Int, name:String, owner:Null<String>, index:Int, sources:Array<IrInitSource>) {
		this.kind = kind;
		this.name = name;
		this.owner = owner;
		this.index = index;
		this.sources = sources;
	}

	/** Whether the value may be the function's argument `argument`. */
	public function carries(argument:Int):Bool {
		for (source in sources)
			if (source.kind == IrInitSource.ARGUMENT && source.index == argument)
				return true;
		return false;
	}

	public function toString():String
		return '$kind:$name:$owner:$index:${sources.join(",")}';
}

/**
 * What one function gives `IrInitializationCalls`, from its body alone, in one of two forms: what it stores (`stores`: whether its
 * global stores and returns count, and those places with where their values may come from), or what it calls (`calls`: the
 * functions and methods it calls, and each place a value that may be a closure or one of its arguments goes, with where the value
 * may come from). A session keeps each by the function's version (`IrStageMemos.initStores`, `IrStageMemos.initCalls`).
 */
@:nullSafety(Strict)
class IrInitCalls {
	public final arguments:Int;

	/** Whether its global stores and returns take part in what globals and returns carry: it returns a closure or a Dynamic, or stores a global. */
	public var relevant(default, null):Bool;

	/** The functions it calls directly. */
	public final callees:Array<String> = [];

	/** The methods it calls, pairs of the receiver's object (null when the receiver is no object) and the method. */
	public final methods:Array<Null<String>> = [];

	public final flows:Array<IrInitFlow> = [];

	function new(arguments:Int, relevant:Bool) {
		this.arguments = arguments;
		this.relevant = relevant;
	}

	/** A function whose stores do not count, shared. */
	@:processWide("an empty summary, only ever read")
	static final NO_STORES = new IrInitCalls(0, false);

	/** What `fn` stores: kept by the session for its version with `lineage`, else read now from its body. */
	public static function stores(fn:IrFunction, builder:Null<IrBodyBuilder>,
			lineage:Null<compiler.ir.reuse.IrStageMemo.IrLineage>):IrInitCalls
		return kept(fn, builder, lineage, false);

	/** What `fn` calls: kept by the session for its version with `lineage`, else read now from its body. */
	public static function calls(fn:IrFunction, builder:Null<IrBodyBuilder>,
			lineage:Null<compiler.ir.reuse.IrStageMemo.IrLineage>):IrInitCalls
		return kept(fn, builder, lineage, true);

	static function kept(fn:IrFunction, builder:Null<IrBodyBuilder>,
			lineage:Null<compiler.ir.reuse.IrStageMemo.IrLineage>, calls:Bool):IrInitCalls {
		var version = lineage == null ? 0 : lineage.versionOf(fn);
		if (lineage == null || version == 0)
			return read(fn, builder, calls);
		var memo = lineage.memos.contribution(calls ? IrInitializationCalls.CALLS : IrInitializationCalls.STORES),
			known = memo.get(version);
		if (known == null) {
			known = read(fn, builder, calls);
			memo.keep(version, known);
		} else if (lineage.checks && known.toString() != read(fn, builder, calls).toString())
			throw new compiler.core
				.InternalError('--check-reuse: the initialization calls reused for ${fn.name} differ from its body');
		return known;
	}

	/** What `fn` gives, read from its body: what it calls with `calls`, else what it stores. */
	public static function read(fn:IrFunction, builder:Null<IrBodyBuilder>, calls:Bool):IrInitCalls {
		var body = fn.encodedBody(builder);
		var made = new IrInitCalls(body.argumentCount(), switch fn.result {
			case Function(_, _), Dyn: true;
			case _: false;
		});
		// Only a function that returns a closure or a Dynamic, or stores a global, stores anything that counts.
		if (!calls && !made.relevant && !storesGlobal(body))
			return NO_STORES;
		var origins:Array<Null<Array<IrInitSource>>> = [], seeded = false, called:Map<String, Bool> = [];
		origins.resize(body.valueLimit());
		inline function seed(value:Int, source:IrInitSource):Void {
			origins[value] = [source];
			seeded = true;
		}
		if (calls)
			for (index in 0...body.argumentCount())
				seed(body.argument(index), new IrInitSource(IrInitSource.ARGUMENT, "", null, index));
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var out:Int = body.output(row);
				switch body.opcode(row) {
					case IrOpcode.GlobalSet:
						made.relevant = true;
					case IrOpcode.StaticClosure, IrOpcode.InstanceClosure:
						seed(out, new IrInitSource(IrInitSource.CLOSURE, body.symbol(row).name, null, 0));
					case IrOpcode.GlobalGet:
						seed(out, new IrInitSource(IrInitSource.GLOBAL, body.symbol(row).name, null, 0));
					case IrOpcode.Call:
						var callee = body.symbol(row).name;
						if (calls && !called.exists(callee)) {
							called.set(callee, true);
							made.callees.push(callee);
						}
						if (out >= 0)
							seed(out, new IrInitSource(IrInitSource.RETURNED, callee, null, 0));
					case IrOpcode.MethodCall:
						var owner = ownerOf(body.valueType(body.operand(row, 0))), method = body.symbol(row).name;
						if (calls && !made.hasMethod(owner, method)) {
							made.methods.push(owner);
							made.methods.push(method);
						}
						if (out >= 0)
							seed(out, new IrInitSource(IrInitSource.METHOD_RETURNED, method, owner, 0));
					case _:
				}
				row = body.nextRow(row);
			}
		}
		if (!seeded)
			return made;
		propagate(body, origins);
		inline function sourcesOf(value:Int):Null<Array<IrInitSource>>
			return value >= 0 && value < origins.length ? origins[value] : null;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				switch body.opcode(row) {
					case IrOpcode.GlobalSet if (!calls):
						var sources = sourcesOf(body.operand(row, 0));
						if (sources != null)
							made.flows.push(new IrInitFlow(IrInitFlow.GLOBAL_SET, body.symbol(row).name, null, 0,
								sources));
					case IrOpcode.Return if (!calls && made.relevant):
						var sources = sourcesOf(body.operand(row, 0));
						if (sources != null)
							made.flows.push(new IrInitFlow(IrInitFlow.RETURN, "", null, 0, sources));
					case IrOpcode.CallClosure if (calls):
						var sources = sourcesOf(body.operand(row, 0));
						if (sources != null)
							made.flows.push(new IrInitFlow(IrInitFlow.CLOSURE_CALL, "", null, 0, sources));
					case IrOpcode.Call if (calls):
						for (index in 0...body.operandCount(row)) {
							var sources = sourcesOf(body.operand(row, index));
							if (sources != null)
								made.flows.push(new IrInitFlow(IrInitFlow.CALL_ARGUMENT, body.symbol(row).name, null,
									index,
									sources));
						}
					case IrOpcode.MethodCall if (calls):
						var owner:Null<String> = null;
						for (index in 1...body.operandCount(row)) {
							var sources = sourcesOf(body.operand(row, index));
							if (sources != null) {
								if (owner == null)
									owner = ownerOf(body.valueType(body.operand(row, 0)));
								made.flows.push(new IrInitFlow(IrInitFlow.METHOD_ARGUMENT, body.symbol(row).name, owner,
									index,
									sources));
							}
						}
					case _:
				}
				row = body.nextRow(row);
			}
		}
		return made;
	}

	static function storesGlobal(body:IrBody):Bool {
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.GlobalSet)
					return true;
				row = body.nextRow(row);
			}
		}
		return false;
	}

	function hasMethod(owner:Null<String>, method:String):Bool {
		var index = 0;
		while (index < methods.length) {
			if (methods[index] == owner && methods[index + 1] == method)
				return true;
			index += 2;
		}
		return false;
	}

	static function ownerOf(receiver:IrType):Null<String>
		return switch receiver {
			case Obj(name): name;
			case _: null;
		};

	/** Carries the sources of `origins`, by value, through SSA aliases, joins and the fields of one receiver. */
	static function propagate(body:IrBody, origins:Array<Null<Array<IrInitSource>>>):Void {
		var fields:Map<String, Array<IrInitSource>> = [];
		// Adds `from` to the sources of `output`.
		function flow(from:Null<Array<IrInitSource>>, output:Int):Bool {
			var changed = false;
			if (from != null)
				for (origin in from) {
					var to = origins[output];
					if (to == null)
						origins[output] = to = [];
					if (!to.contains(origin)) {
						to.push(origin);
						changed = true;
					}
				}
			return changed;
		}
		inline function sourcesOf(value:Int):Null<Array<IrInitSource>>
			return value >= 0 && value < origins.length ? origins[value] : null;
		var changed = true;
		while (changed) {
			changed = false;
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0) {
					var opcode = body.opcode(row), output:Int = body.output(row);
					var stored = opcode == IrOpcode.FieldSet ? sourcesOf(body.operand(row, 1)) : null;
					if (stored != null) {
						var key = (body.operand(row, 0):Int) + ":" + body.symbol(row).name, field = fields.get(key);
						if (field == null)
							fields.set(key, field = []);
						for (origin in stored)
							if (!field.contains(origin)) {
								field.push(origin);
								changed = true;
							}
					}
					if (output >= 0) {
						if (opcode == IrOpcode.FieldGet) {
							var field = fields.get((body.operand(row, 0):Int) + ":" + body.symbol(row).name);
							if (flow(field, output))
								changed = true;
						}
						switch opcode {
							case IrOpcode.SafeCast, IrOpcode.ToDyn, IrOpcode.ToVirtual, IrOpcode.Upcast:
								if (flow(sourcesOf(body.operand(row, 0)), output))
									changed = true;
							case IrOpcode.Phi:
								for (index in 0...body.operandCount(row))
									if (flow(sourcesOf(body.operand(row, index)), output))
										changed = true;
							case _:
						}
					}
					row = body.nextRow(row);
				}
			}
		}
	}

	public function toString():String
		return '$arguments:$relevant:${callees.join(",")}:${methods.join(",")}:${flows.join(";")}';
}
