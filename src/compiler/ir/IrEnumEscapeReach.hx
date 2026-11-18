package compiler.ir;

import compiler.ir.Ir;
import compiler.semantic.SemanticSignature;

/** The shared transitive storage reach of Dynamic, reflection, descriptors and host boundaries.
 * Value-layout classification remains with its caller; reference traversal is defined only here.
 */
class IrEnumEscapeReach {
	final objects:Map<String, IrObject>;
	final contracts:Map<String, IrInterface>;
	final declarations:Map<String, IrEnum>;
	final functions:Map<String, IrFunction>;
	final staticFieldsByOwner:Map<String, Array<IrStaticField>> = [];
	final mapContents = new IrTypeMap<Array<IrType>>();
	final subclasses:Map<String, Array<IrObject>> = [];
	final closureEnvironments = new IrTypeMap<Array<IrType>>();
	final interfaceImplementers:Map<String, Array<IrObject>> = [];
	final interfaceClosures:Map<String, Map<String, Bool>> = [];
	final objectClosures:Map<String, Map<String, Bool>> = [];
	var implementersBuilt = false;

	public function new(program:IrProgram) {
		objects = [for (entry in program.objects) entry.name => entry];
		contracts = [for (entry in program.interfaces) entry.name => entry];
		declarations = [for (entry in program.enums) entry.name => entry];
		functions = [for (entry in program.functions) entry.name => entry];
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
		for (object in program.objects)
			if (object.base != null) {
				var children = subclasses.get(object.base);
				if (children == null) {
					children = [];
					subclasses.set(object.base, children);
				}
				children.push(object);
			}
		for (fn in functions)
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case InstanceClosure(output, _, receiver):
							var environments = closureEnvironments.get(output.type);
							if (environments == null) {
								environments = [];
								closureEnvironments.set(output.type, environments);
							}
							environments.push(receiver.type);
						case Call(_, name, arguments)
							if (StringTools.startsWith(name.name, "__map_")
							&& StringTools.contains(name.name, "_ref_")
							&& StringTools.endsWith(name.name, "_set")
							&& arguments.length >= 3):
							var contents = mapContents.get(arguments[0].type);
							if (contents == null) {
								contents = [];
								mapContents.set(arguments[0].type, contents);
							}
							contents.push(arguments[1].type);
							contents.push(arguments[arguments.length - 1].type);
						default:
					}
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

	public function collect(roots:Array<IrType>, supportsCallableEscape:IrType->Bool):Map<String, Bool> {
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
				var fn = functions.get(method.functionName);
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
		for (root in roots) {
			inspect(root, true);
			walkReferences(root);
		}
		return unsupported;
	}
}
