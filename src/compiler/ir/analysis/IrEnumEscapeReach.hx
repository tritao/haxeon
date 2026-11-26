package compiler.ir.analysis;

import compiler.ir.model.IrFunction;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrTypeIds;
import compiler.ir.model.IrTypeMap;
import compiler.ir.reuse.IrStageMemo.IrStageMemos;

import compiler.ir.model.Ir;
import compiler.semantic.SemanticSignature;

/** The shared transitive storage reach of Dynamic, reflection, descriptors and host boundaries.
 * Value-layout classification remains with its caller; reference traversal is defined only here.
 */
@:nullSafety(Strict)
class IrEnumEscapeReach {
	// The program's tables by name, made when the reach first walks (`index`): a session that keeps the walk reads none of them.
	final objects:Map<String, IrObject> = [];
	final contracts:Map<String, IrInterface> = [];
	final declarations:Map<String, IrEnum> = [];
	final functions:Map<String, IrFunction> = [];
	final staticFieldsByOwner:Map<String, Array<IrStaticField>> = [];
	final mapContents = new IrTypeMap<Array<IrType>>();
	final subclasses:Map<String, Array<IrObject>> = [];
	final closureEnvironments = new IrTypeMap<Array<IrType>>();
	final interfaceImplementers:Map<String, Array<IrObject>> = [];
	final interfaceClosures:Map<String, Map<String, Bool>> = [];
	final objectClosures:Map<String, Map<String, Bool>> = [];
	var implementersBuilt = false;
	var indexed = false;

	/** The program this reach was made for (`collectEach`). */
	final program:IrProgram;

	/**
	 * The closures' environments given (`closureEnvironment`), as pairs in order, and the map stores (`mapContent`), as triples,
	 * by type id, so a kept reach compares them as integers.
	 */
	final closureLog:Array<Int> = [];

	final mapLog:Array<Int> = [];

	/** The session's walk or step under way, which records the signatures the reach reads (`IrWalkMemo.signature`). */
	var recording:Null<compiler.ir.reuse.IrWalkMemo<Dynamic, Dynamic>> = null;

	/**
	 * `scans`, when given, tells the functions whose closures and map stores to read: the others have none.
	 */
	public function new(program:IrProgram, ?scans:IrFunction->Bool) {
		this.program = program;
		for (fn in program.functions)
			if (scans == null || scans(fn))
				give(storesOf(fn));
	}

	/** Gives the reach what a function gives it (`storesOf`). */
	function give(stores:Array<Array<Int>>):Void {
		for (type in stores[0])
			closureLog.push(type);
		for (type in stores[1])
			mapLog.push(type);
	}

	static function sameStores(left:Array<Array<Int>>, right:Array<Array<Int>>):Bool
		return IrTypeIds.sameList(left[0], right[0]) && IrTypeIds.sameList(left[1], right[1]);

	/**
	 * The enums `roots` reach in `program`, given the closures and map stores of every function. In a session it is the session's
	 * step `name` (`IrWalkMemo`), whose summary of a function is what it gives (`storesOf`): last build's result while the program
	 * and the roots give it the same; else walked again. With `--check-reuse` a kept result is walked again and compared.
	 */
	public static function collectStores(name:String, program:IrProgram, roots:Array<IrType>,
			stageMemos:Null<IrStageMemos>):Map<String, Bool> {
		var reach = new IrEnumEscapeReach(program, _ -> false);
		if (stageMemos == null) {
			for (fn in program.functions)
				reach.give(storesOf(fn));
			return reach.collect(roots, _ -> false);
		}
		var lists = [roots],
			memo:compiler.ir.reuse.IrWalkMemo<Array<Array<Int>>, Map<String, Bool>> = stageMemos.step(name, sameStores),
			kept = memo.kept(stageMemos.database, program, program.functions, reach.givenOf(lists),
				reach.givenTypesOf(lists),
				storesOf);
		if (kept != null) {
			if (stageMemos.checks && !sameResults([collectStores(name, program, roots, null)], [kept]))
				throw new compiler.core
					.InternalError('--check-reuse: the escape reach $name reused results that differ from walking it now');
			return kept.copy();
		}
		memo.begin(stageMemos.database);
		for (fn in program.functions)
			reach.give(memo.summary(fn));
		reach.recording = cast memo;
		var result = reach.collect(roots, _ -> false);
		reach.recording = null;
		memo.end(stageMemos.database, result.copy());
		return result;
	}

	/** What `fn` gives the reach; a function read past the encode point is its body, one before it its objects. */
	static function storesOf(fn:IrFunction):Array<Array<Int>> {
		var closures:Array<Int> = [], maps:Array<Int> = [], body = fn.body;
		if (body != null)
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0) {
					switch body.opcode(row) {
						case IrOpcode.InstanceClosure:
							closures.push(body.valueTypeId(body.output(row)));
							closures.push(body.valueTypeId(body.operand(row, 0)));
						case IrOpcode.Call if (body.operandCount(row) >= 3 && mapSetter(body.symbol(row).name)):
							maps.push(body.valueTypeId(body.operand(row, 0)));
							maps.push(body.valueTypeId(body.operand(row, 1)));
							maps.push(body.valueTypeId(body.operand(row, body.operandCount(row) - 1)));
						default:
					}
					row = body.nextRow(row);
				}
			}
				else
				for (block in fn.blocks)
					for (located in block.instructions)
						switch located.value {
							case InstanceClosure(output, _, receiver):
								closures.push(IrTypeIds.id(output.type));
								closures.push(IrTypeIds.id(receiver.type));
							case Call(_, name, arguments) if (arguments.length >= 3 && mapSetter(name.name)):
								maps.push(IrTypeIds.id(arguments[0].type));
								maps.push(IrTypeIds.id(arguments[1].type));
								maps.push(IrTypeIds.id(arguments[arguments.length - 1].type));
							default:
						}
		return [closures, maps];
	}

	/** Indexes the program's tables by name, and the closures and map stores given by type, once, before the reach first walks. */
	function index():Void {
		if (indexed)
			return;
		indexed = true;
		var position = 0;
		while (position < closureLog.length) {
			var closure = IrTypeIds.type(closureLog[position]), environments = closureEnvironments.get(closure);
			if (environments == null) {
				environments = [];
				closureEnvironments.set(closure, environments);
			}
			environments.push(IrTypeIds.type(closureLog[position + 1]));
			position += 2;
		}
		position = 0;
		while (position < mapLog.length) {
			var map = IrTypeIds.type(mapLog[position]), contents = mapContents.get(map);
			if (contents == null) {
				contents = [];
				mapContents.set(map, contents);
			}
			contents.push(IrTypeIds.type(mapLog[position + 1]));
			contents.push(IrTypeIds.type(mapLog[position + 2]));
			position += 3;
		}
		for (entry in program.objects)
			objects.set(entry.name, entry);
		for (entry in program.interfaces)
			contracts.set(entry.name, entry);
		for (entry in program.enums)
			declarations.set(entry.name, entry);
		for (entry in program.functions)
			functions.set(entry.name, entry);
		for (field in program.staticFields) {
			var separator = field.name.indexOf(".");
			while (separator >= 0) {
				var owner = field.name.substr(0, separator);
				if (objects.exists(owner)) {
					var fields = staticFieldsByOwner.get(owner);
					if (fields == null) {
						fields = [];
						staticFieldsByOwner.set(owner, fields);
					}
					fields.push(field);
				}
				separator = field.name.indexOf(".", separator + 1);
			}
		}
		for (object in program.objects) {
			var base = object.base;
			if (base != null) {
				var children = subclasses.get(base);
				if (children == null) {
					children = [];
					subclasses.set(base, children);
				}
				children.push(object);
			}
		}
	}

	public static function mapSetter(name:String):Bool
		return StringTools.startsWith(name, "__map_") && StringTools.contains(name, "_ref_")
			&& StringTools.endsWith(name, "_set");

	/** Gives the reach a closure of type id `closure` over one of type id `receiver`; before it walks. */
	public function closureEnvironment(closure:Int, receiver:Int):Void {
		closureLog.push(closure);
		closureLog.push(receiver);
	}

	/** Gives the reach a store of `key` and `value` in a map of type `map`, all type ids; before it walks. */
	public function mapContent(map:Int, key:Int, value:Int):Void {
		mapLog.push(map);
		mapLog.push(key);
		mapLog.push(value);
	}

	/** Opaque native handles do not expose the contents of a container stored behind them.
	 * A reflective root that reaches the same map through a field still follows its contents.
	 */
	public static function addNativeRoot(roots:Array<IrType>, type:IrType):Void
		switch type {
			case Abstract(_):
			default:
				roots.push(type);
		}

	function values(type:IrType, output:Map<String, Bool>, seen:Map<String, Bool>):Void
		switch type {
			case Enum(name), EnumTag(name):
				output.set(name, true);
				var declaration = declarations.get(name);
				if (declaration != null && !seen.exists("enum:" + name)) {
					seen.set("enum:" + name, true);
					for (entry in declaration.cases)
						for (part in entry.params)
							values(part, output, seen);
				}
			case Nullable(inner), Array(inner), Iterator(inner):
				values(inner, output, seen);
			case Function(arguments, result):
				for (argument in arguments)
					values(argument, output, seen);
				values(result, output, seen);
			case Obj(name):
				var object = objects.get(name);
				if (object != null && object.isValue && !seen.exists(name)) {
					seen.set(name, true);
					for (field in object.fields)
						values(field.type, output, seen);
				}
			default:
		}

	/** The enums `roots` reach that are not a callable `supportsCallableEscape` accepts. */
	public function collect(roots:Array<IrType>, supportsCallableEscape:IrType->Bool):Map<String, Bool>
		return walker(supportsCallableEscape)(roots);

	/** `collect` as the session's walk `name` (`collectEach`). */
	public function collectWalked(name:String, roots:Array<IrType>, supportsCallableEscape:IrType->Bool,
			stageMemos:Null<IrStageMemos>):Map<String, Bool>
		return collectEach(name, [roots], supportsCallableEscape, stageMemos)[0];

	/**
	 * The enums one walk reaches after each list of `lists` (`walker`), each a map of its own. In a session the walk is the session's
	 * walk `name` (`IrWalkMemo`): last build's results while this reach reads what last build's did, the lists are the same and
	 * `supportsCallableEscape` answers what it answered then; else walked again. With `--check-reuse` kept results are walked again
	 * and compared.
	 *
	 * Besides the program's tables, a reach reads the signature of the function each object method names, the closures and map
	 * stores it was given in order, and the lists. It follows no function's edges.
	 */
	public function collectEach(name:String, lists:Array<Array<IrType>>, supportsCallableEscape:IrType->Bool,
			stageMemos:Null<IrStageMemos>):Array<Map<String, Bool>> {
		if (stageMemos == null)
			return walkEach(lists, supportsCallableEscape);
		var memo:compiler.ir.reuse.IrWalkMemo<IrTypeAwareWalk.IrWalkSummary, IrEscapeResults> = stageMemos.walk(name),
			kept = memo.kept(stageMemos.database, program, methodFunctionsOf(), givenOf(lists), givenTypesOf(lists),
				null);
		if (kept != null && sameAnswers(kept, supportsCallableEscape)) {
			if (stageMemos.checks && !sameResults(walkEach(lists, supportsCallableEscape), kept.results))
				throw new compiler.core
					.InternalError('--check-reuse: the escape reach $name reused results that differ from walking it now');
			return [for (result in kept.results) result.copy()];
		}
		memo.begin(stageMemos.database);
		recording = cast memo;
		var asked:Array<IrType> = [], answers:Array<Bool> = [];
		var results = walkEach(lists, type -> {
			var answer = supportsCallableEscape(type);
			asked.push(type);
			answers.push(answer);
			answer;
		});
		recording = null;
		memo.end(stageMemos.database,
			{results: [for (result in results) result.copy()], asked: asked, answers: answers});
		return results;
	}

	/** What a kept reach is given besides the program: how many closures, map stores and roots of each list, as names... */
	function givenOf(lists:Array<Array<IrType>>):Array<String> {
		var given = ['closures ${closureLog.length}', 'maps ${mapLog.length}'];
		for (roots in lists)
			given.push('roots ${roots.length}');
		return given;
	}

	/** ...and the closures, the map stores and the roots, as type ids. */
	function givenTypesOf(lists:Array<Array<IrType>>):Array<Int> {
		var givenTypes = closureLog.concat(mapLog);
		for (roots in lists)
			for (root in roots)
				givenTypes.push(IrTypeIds.id(root));
		return givenTypes;
	}

	/** The functions the methods name, in program order, found without indexing every function by name. */
	function methodFunctionsOf():Array<IrFunction> {
		var methodNames:Map<String, Bool> = [];
		for (object in program.objects)
			for (method in object.methods)
				methodNames.set(method.functionName.name, true);
		return [for (fn in program.functions) if (methodNames.exists(fn.name)) fn];
	}

	/** Whether `supportsCallableEscape` answers what the walk that found `kept` was answered. */
	static function sameAnswers(kept:IrEscapeResults, supportsCallableEscape:IrType->Bool):Bool {
		for (index in 0...kept.asked.length)
			if (supportsCallableEscape(kept.asked[index]) != kept.answers[index])
				return false;
		return true;
	}

	/** Whether two walks found the same, for `--check-reuse`. */
	static function sameResults(left:Array<Map<String, Bool>>, right:Array<Map<String, Bool>>):Bool {
		if (left.length != right.length)
			return false;
		for (index in 0...left.length) {
			for (name in left[index].keys())
				if (!right[index].exists(name))
					return false;
			for (name in right[index].keys())
				if (!left[index].exists(name))
					return false;
		}
		return true;
	}

	function walkEach(lists:Array<Array<IrType>>, supportsCallableEscape:IrType->Bool):Array<Map<String, Bool>> {
		var walk = walker(supportsCallableEscape);
		return [for (roots in lists) walk(roots).copy()];
	}

	/**
	 * A walk that takes roots one list after the other and gives, after each, every enum it has reached so far: what one list
	 * reaches through what an earlier one visited, that one reached already, so the walk visits each part of the program once.
	 */
	public function walker(supportsCallableEscape:IrType->Bool):Array<IrType>->Map<String, Bool> {
		index();
		var unsupported:Map<String, Bool> = [],
			visited:Map<String, Bool> = [],
			inspectedMaps = new IrTypeMap<Bool>(), // What the reference walk has visited: named types by name; function and map types, the only other ones that can lead
			// back to themselves, by structure. Wrappers and primitives are not recorded: walking them again is cheap and finite.
			referenceTypes = new IrTypeMap<Bool>(),
			referenceObjects:Map<String, Bool> = [],
			referenceVirtuals:Map<String, Bool> = [],
			valueTypes:Map<String, Bool> = [];

		function interfaceClosure(name:String, path:Array<String>):Map<String, Bool> {
			var existing = interfaceClosures.get(name);
			if (existing != null)
				return existing;
			if (path.contains(name))
				return [];
			var result:Map<String, Bool> = [name => true],
				contract = contracts.get(name),
				next = path.concat([name]);
			if (contract != null)
				for (base in contract.bases)
					for (inherited in interfaceClosure(base, next).keys())
						result.set(inherited, true);
			interfaceClosures.set(name, result);
			return result;
		}
		function objectClosure(name:String, path:Array<String>):Map<String, Bool> {
			var existing = objectClosures.get(name);
			if (existing != null)
				return existing;
			if (path.contains(name))
				return [];
			var object = objects.get(name);
			if (object == null)
				return [];
			var result:Map<String, Bool> = [], next = path.concat([name]);
			if (object.base != null)
				for (inherited in objectClosure(object.base, next).keys())
					result.set(inherited, true);
			for (contract in object.interfaces)
				for (inherited in interfaceClosure(contract, []).keys())
					result.set(inherited, true);
			objectClosures.set(name, result);
			return result;
		}
		function buildInterfaceImplementers():Void {
			if (implementersBuilt)
				return;
			implementersBuilt = true;
			for (object in objects)
				if (!object.isValue)
					for (name in objectClosure(object.name, []).keys()) {
						var entries = interfaceImplementers.get(name);
						if (entries == null) {
							entries = [];
							interfaceImplementers.set(name, entries);
						}
						entries.push(object);
					}
		}

		function inspect(type:IrType, allowCallable:Bool):Void {
			if (!(allowCallable && supportsCallableEscape(type)))
				values(type, unsupported, valueTypes);
			switch type {
				case Abstract(_):
					if (inspectedMaps.exists(type))
						return;
					inspectedMaps.set(type, true);
					var contents = mapContents.get(type);
					if (contents != null)
						for (content in contents)
							inspect(content, true);
				default:
			}
		}
		var walk:IrObject->Void = function(_) {},
			referenceEnums:Map<String, Bool> = [];
		function firstReference(type:IrType):Bool {
			if (referenceTypes.exists(type))
				return false;
			referenceTypes.set(type, true);
			return true;
		}
		function walkReferences(type:IrType):Void {
			switch type {
				case Enum(name), EnumTag(name):
					if (!referenceEnums.exists(name)) {
						referenceEnums.set(name, true);
						var declaration = declarations.get(name);
						if (declaration != null)
							for (entry in declaration.cases)
								for (part in entry.params) {
									inspect(part, true);
									walkReferences(part);
								}
					}
				case Obj(name):
					if (referenceObjects.exists(name))
						return;
					referenceObjects.set(name, true);
					var child = objects.get(name);
					if (child != null) {
						if (child.isValue)
							for (field in child.fields)
								walkReferences(field.type);
							else
								walk(child);
					}
				case Nullable(inner), Array(inner), Iterator(inner):
					walkReferences(inner);
				case Function(arguments, result):
					if (!firstReference(type))
						return;
					for (argument in arguments)
						walkReferences(argument);
					walkReferences(result);
					var environments = closureEnvironments.get(type);
					if (environments != null)
						for (environment in environments)
							walkReferences(environment);
				case Virtual(name):
					if (referenceVirtuals.exists(name))
						return;
					referenceVirtuals.set(name, true);
					var anonymous = objects.get(name);
					if (anonymous != null && SemanticSignature.isAnonymousName(name))
						walk(anonymous);
					buildInterfaceImplementers();
					var implementers = interfaceImplementers.get(name);
					if (implementers != null)
						for (object in implementers)
							walk(object);
				case Abstract(_):
					if (referenceTypes.exists(type))
						return;
					referenceTypes.set(type, true);
					var contents = mapContents.get(type);
					if (contents != null)
						for (content in contents)
							walkReferences(content);
				default:
			}
		}
		walk = function(current:IrObject):Void {
			if (visited.exists(current.name))
				return;
			visited.set(current.name, true);
			for (field in current.fields) {
				inspect(field.type, true);
				walkReferences(field.type);
			}
			var staticFields = staticFieldsByOwner.get(current.name);
			if (staticFields != null)
				for (field in staticFields) {
					inspect(field.type, true);
					walkReferences(field.type);
				}
			for (method in current.methods) {
				var fn = functions.get(method.functionName.name);
				if (fn != null) {
					var session = recording;
					if (session != null)
						session.signature(fn);
					var signature = Function([for (argument in fn.arguments) argument.type], fn.result);
					inspect(signature, false);
					walkReferences(signature);
				}
			}
			if (current.base != null) {
				var base = objects.get(current.base);
				if (base != null)
					walk(base);
			}
			var children = subclasses.get(current.name);
			if (children != null)
				for (child in children)
					walk(child);
		};
		return function(roots:Array<IrType>):Map<String, Bool> {
			for (root in roots) {
				inspect(root, true);
				walkReferences(root);
			}
			return unsupported;
		};
	}
}

/**
 * The results of an escape reach a session keeps (`IrEnumEscapeReach.collectEach`), with each type the walk asked whether it is a
 * supported callable and the answer it got.
 */
typedef IrEscapeResults = {
	final results:Array<Map<String, Bool>>;
	final asked:Array<IrType>;
	final answers:Array<Bool>;
}
