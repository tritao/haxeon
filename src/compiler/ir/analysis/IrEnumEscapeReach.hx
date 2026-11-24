package compiler.ir.analysis;

import compiler.ir.model.IrFunction;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrTypeIdentity;
import compiler.ir.model.IrTypeMap;
import compiler.ir.reuse.IrStageMemo.IrContributionKey;
import compiler.ir.reuse.IrStageMemo.IrLineage;
import compiler.ir.reuse.IrWalkRecord;

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

	/** The closures' environments given (`closureEnvironment`), as pairs in order, and the map stores (`mapContent`), as triples. */
	final closureLog:Array<IrType> = [];

	final mapLog:Array<IrType> = [];

	/**
	 * What each function gives the reach: the closures it makes, as pairs of the closure's type and its receiver's, and the map
	 * stores, as triples of the map's type, the key's and the value's.
	 */
	@:processWide("a contribution memo's key, only ever read")
	public static final STORES = new IrContributionKey<Array<Array<IrType>>>("escape-stores");

	/**
	 * `scans`, when given, tells the functions whose closures and map stores to read: the others have none. With `lineage`, what
	 * each function gives is read once per version (`STORES`).
	 */
	public function new(program:IrProgram, ?scans:IrFunction->Bool, ?lineage:IrLineage) {
		this.program = program;
		for (fn in program.functions) {
			if (scans != null && !scans(fn))
				continue;
			var version = lineage == null ? 0 : lineage.versionOf(fn), stores:Null<Array<Array<IrType>>> = null;
			if (lineage != null && version != 0) {
				var memo = lineage.memos.contribution(STORES);
				stores = memo.get(version);
				if (stores == null) {
					stores = storesOf(fn);
					memo.keep(version, stores);
				} else if (lineage.checks && !sameStores(stores, storesOf(fn)))
					throw new compiler.core
						.InternalError('--check-reuse: the escape stores reused for ${fn.name} differ from its instructions');
			} else
				stores = storesOf(fn);
			for (type in stores[0])
				closureLog.push(type);
			for (type in stores[1])
				mapLog.push(type);
		}
	}

	static function sameStores(left:Array<Array<IrType>>, right:Array<Array<IrType>>):Bool
		return IrTypeIdentity.sameList(left[0], right[0]) && IrTypeIdentity.sameList(left[1], right[1]);

	/** What `fn` gives the reach (`STORES`); a function read past the encode point is its body, one before it its objects. */
	static function storesOf(fn:IrFunction):Array<Array<IrType>> {
		var closures:Array<IrType> = [], maps:Array<IrType> = [], body = fn.body;
		if (body != null)
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0) {
					switch body.opcode(row) {
						case IrOpcode.InstanceClosure:
							closures.push(body.valueType(body.output(row)));
							closures.push(body.valueType(body.operand(row, 0)));
						case IrOpcode.Call if (body.operandCount(row) >= 3 && mapSetter(body.symbol(row).name)):
							maps.push(body.valueType(body.operand(row, 0)));
							maps.push(body.valueType(body.operand(row, 1)));
							maps.push(body.valueType(body.operand(row, body.operandCount(row) - 1)));
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
								closures.push(output.type);
								closures.push(receiver.type);
							case Call(_, name, arguments) if (arguments.length >= 3 && mapSetter(name.name)):
								maps.push(arguments[0].type);
								maps.push(arguments[1].type);
								maps.push(arguments[arguments.length - 1].type);
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
			var closure = closureLog[position], environments = closureEnvironments.get(closure);
			if (environments == null) {
				environments = [];
				closureEnvironments.set(closure, environments);
			}
			environments.push(closureLog[position + 1]);
			position += 2;
		}
		position = 0;
		while (position < mapLog.length) {
			var map = mapLog[position], contents = mapContents.get(map);
			if (contents == null) {
				contents = [];
				mapContents.set(map, contents);
			}
			contents.push(mapLog[position + 1]);
			contents.push(mapLog[position + 2]);
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

	/** Gives the reach a closure of type `closure` over `receiver`; before it walks. */
	public function closureEnvironment(closure:IrType, receiver:IrType):Void {
		closureLog.push(closure);
		closureLog.push(receiver);
	}

	/** Gives the reach a store of `key` and `value` in a map of type `map`; before it walks. */
	public function mapContent(map:IrType, key:IrType, value:IrType):Void {
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

	/** `collect` in a session that keeps the result as `key` (`collectEach`). */
	public function collectKept(key:IrContributionKey<IrWalkRecord<Bool, IrEscapeResults>>, roots:Array<IrType>,
			supportsCallableEscape:IrType->Bool, lineage:Null<IrLineage>):Map<String, Bool>
		return collectEach(key, [roots], supportsCallableEscape, lineage)[0];

	/**
	 * The enums one walk reaches after each list of `lists` (`walker`), each a map of its own. In a session that keeps the results
	 * as `key` (`IrWalkRecord`), last build's while this reach reads what last build's did, the lists are the same and
	 * `supportsCallableEscape` answers what it answered then; else walked and kept. With `--check-reuse` kept results are walked
	 * again and compared.
	 *
	 * Besides the program's tables, a reach reads the signature of the function each object method names, the closures and map
	 * stores it was given in order, and the lists. It follows no function's edges, so its record keeps no summaries.
	 */
	public function collectEach(key:IrContributionKey<IrWalkRecord<Bool, IrEscapeResults>>, lists:Array<Array<IrType>>,
			supportsCallableEscape:IrType->Bool, lineage:Null<IrLineage>):Array<Map<String, Bool>> {
		if (lineage == null)
			return walkEach(lists, supportsCallableEscape);
		var given = ['closures ${closureLog.length}', 'maps ${mapLog.length}'],
			givenTypes = closureLog.concat(mapLog);
		for (roots in lists) {
			given.push('roots ${roots.length}');
			for (root in roots)
				givenTypes.push(root);
		}
		// The functions the methods name, in program order, found without indexing every function by name.
		var methodNames:Map<String, Bool> = [];
		for (object in program.objects)
			for (method in object.methods)
				methodNames.set(method.functionName.name, true);
		var methodFunctions = [for (fn in program.functions) if (methodNames.exists(fn.name)) fn];
		var memos = lineage.memos,
			last = memos.lastResult(key),
			kept = last == null ? null : last.holds(program, given, givenTypes, methodFunctions, (_, _) -> null);
		if (kept != null && sameAnswers(kept.result, supportsCallableEscape)) {
			if (lineage.checks && !sameResults(walkEach(lists, supportsCallableEscape), kept.result.results))
				throw new compiler.core
					.InternalError('--check-reuse: the escape reach ${key.name} reused results that differ from walking it now');
			memos.keepResult(key, kept);
			return [for (result in kept.result.results) result.copy()];
		}
		var asked:Array<IrType> = [], answers:Array<Bool> = [];
		var results = walkEach(lists, type -> {
			var answer = supportsCallableEscape(type);
			asked.push(type);
			answers.push(answer);
			answer;
		});
		memos.keepResult(key,
			new IrWalkRecord(program, given, givenTypes, methodFunctions, [for (_ in methodFunctions) null],
			{
				results: [for (result in results) result.copy()],
				asked: asked,
				answers: answers
			}));
		return results;
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
