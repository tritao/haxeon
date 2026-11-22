package compiler.ir.model;

import compiler.ir.analysis.IrEntryPrune;
import compiler.ir.model.Ir.IrInterface;
import compiler.ir.model.Ir.IrObject;
import compiler.ir.model.Ir.IrProgram;

/**
 * Name lookups over one IR program, for reachability and the backends.
 *
 * Virtual dispatch and reachability ask, for each call site, which classes
 * extend or implement a type. Answering that by scanning `program.objects`
 * made those passes quadratic in the number of classes; this index answers
 * each lookup by name and remembers the subtype sets it has computed.
 */
class IrProgramIndex {
	final program:IrProgram;
	final functionCount:Int;
	final objectCount:Int;
	final interfaceCount:Int;
	final functions:Map<String, IrFunction> = [];
	final objects:Map<String, IrObject> = [];
	final interfaces:Map<String, IrInterface> = [];
	final subtypes:Map<String, Array<IrObject>> = [];

	/**
	 * For each class name, the names whose class extends it directly, and where each name's classes are in `program.objects`;
	 * made on the first `subtypesOf`. A name's base is its first class's, as `isObjectSubtype` follows it.
	 */
	var subclassNames:Null<Map<String, Array<String>>> = null;

	var positionsByName:Map<String, Array<Int>> = [];

	/**
	 * For each interface, the classes implementing it, in declaration order; filled for every interface in one pass on the
	 * first `implementorsOf`. A class is listed under what its name's first class implements, as `implementsInterface` has it.
	 */
	var implementors:Null<Map<String, Array<IrObject>>> = null;

	/** The index for `program`, kept on it and rebuilt when its declaration arrays change. */
	public static function of(program:IrProgram):IrProgramIndex {
		var index = program.index;
		if (index == null || !index.matches(program)) {
			index = new IrProgramIndex(program);
			program.index = index;
		}
		return index;
	}

	function new(program:IrProgram) {
		this.program = program;
		functionCount = program.functions.length;
		objectCount = program.objects.length;
		interfaceCount = program.interfaces.length;
		// Later declarations win, matching the scans this replaces.
		for (fn in program.functions)
			functions.set(fn.name, fn);
		for (object in program.objects)
			if (!objects.exists(object.name))
				objects.set(object.name, object);
		for (interfaceDecl in program.interfaces)
			if (!interfaces.exists(interfaceDecl.name))
				interfaces.set(interfaceDecl.name, interfaceDecl);
	}

	function matches(program:IrProgram):Bool
		return this.program == program
			&& functionCount == program.functions.length
			&& objectCount == program.objects.length
			&& interfaceCount == program.interfaces.length;

	public function func(name:String):Null<IrFunction>
		return functions.get(name);

	public function object(name:String):Null<IrObject>
		return objects.get(name);

	public function isObjectSubtype(actual:String, expected:String):Bool {
		var current:Null<String> = actual;
		while (current != null) {
			if (current == expected)
				return true;
			var object = objects.get(current);
			current = object == null ? null : object.base;
		}
		return false;
	}

	public function implementsInterface(objectName:String, interfaceName:String):Bool {
		var current:Null<String> = objectName;
		while (current != null) {
			var object = objects.get(current);
			if (object == null)
				return false;
			for (implemented in object.interfaces)
				if (interfaceExtends(implemented, interfaceName))
					return true;
			current = object.base;
		}
		return false;
	}

	public function interfaceExtends(actual:String, expected:String):Bool {
		if (actual == expected)
			return true;
		var interfaceDecl = interfaces.get(actual);
		if (interfaceDecl != null)
			for (base in interfaceDecl.bases)
				if (interfaceExtends(base, expected))
					return true;
		return false;
	}

	public function inheritanceDepth(typeName:String):Int {
		var depth = 0, object = objects.get(typeName);
		while (object != null && object.base != null) {
			depth++;
			object = objects.get(object.base);
		}
		return depth;
	}

	public function findMethod(objectName:String, methodName:String):Null<String> {
		var current:Null<String> = objectName;
		while (current != null) {
			var object = objects.get(current);
			if (object == null)
				return null;
			for (method in object.methods)
				if (method.name == methodName)
					return method.functionName.name;
			IrEntryPrune.noteMethodLookup(current, methodName);
			current = object.base;
		}
		return null;
	}

	/** Classes that are `typeName` or extend it, in declaration order. */
	public function subtypesOf(typeName:String):Array<IrObject> {
		var result = subtypes.get(typeName);
		if (result == null) {
			var children = subclassNames;
			if (children == null) {
				children = [];
				for (position in 0...program.objects.length) {
					var name = program.objects[position].name, positions = positionsByName.get(name);
					if (positions == null) {
						positions = [];
						positionsByName.set(name, positions);
						var first = objects.get(name), base = first == null ? null : first.base;
						if (base != null) {
							var names = children.get(base);
							if (names == null) {
								names = [];
								children.set(base, names);
							}
							names.push(name);
						}
					}
					positions.push(position);
				}
				subclassNames = children;
			}
			// The names below `typeName` in the class tree, then their classes in declaration order.
			var found:Array<Int> = [], seen:Map<String, Bool> = [typeName => true], pending = [typeName];
			while (pending.length > 0) {
				var name = pending.pop(), positions = positionsByName.get(name), below = children.get(name);
				if (positions != null)
					for (position in positions)
						found.push(position);
				if (below != null)
					for (child in below)
						if (!seen.exists(child)) {
							seen.set(child, true);
							pending.push(child);
						}
			}
			found.sort((a, b) -> a - b);
			result = [for (position in found) program.objects[position]];
			subtypes.set(typeName, result);
		}
		return result;
	}

	/** Classes implementing `interfaceName` directly or through a base, in declaration order. */
	public function implementorsOf(interfaceName:String):Array<IrObject> {
		var byInterface = implementors;
		if (byInterface == null) {
			byInterface = [];
			// Each class is added under every interface its name implements: through its bases, and the interfaces those extend.
			var closures:Map<String, Array<String>> = [], implementedByName:Map<String, Array<String>> = [];
			for (object in program.objects) {
				var implemented = implementedByName.get(object.name);
				if (implemented == null) {
					implemented = [];
					implementedByName.set(object.name, implemented);
					var seen:Map<String, Bool> = [], current:Null<String> = object.name;
					while (current != null) {
						var declared = objects.get(current);
						if (declared == null)
							break;
						for (direct in declared.interfaces)
							for (name in interfaceClosure(direct, closures))
								if (!seen.exists(name)) {
									seen.set(name, true);
									implemented.push(name);
								}
						current = declared.base;
					}
				}
				for (name in implemented) {
					var classes = byInterface.get(name);
					if (classes == null) {
						classes = [];
						byInterface.set(name, classes);
					}
					classes.push(object);
				}
			}
			implementors = byInterface;
		}
		var result = byInterface.get(interfaceName);
		if (result == null) {
			result = [];
			byInterface.set(interfaceName, result);
		}
		return result;
	}

	/** `name` and every interface it extends, directly or not, as `interfaceExtends` follows them. */
	function interfaceClosure(name:String, closures:Map<String, Array<String>>):Array<String> {
		var result = closures.get(name);
		if (result == null) {
			result = [];
			var seen:Map<String, Bool> = [name => true], pending = [name];
			while (pending.length > 0) {
				var next = pending.pop(), interfaceDecl = interfaces.get(next);
				result.push(next);
				if (interfaceDecl != null)
					for (base in interfaceDecl.bases)
						if (!seen.exists(base)) {
							seen.set(base, true);
							pending.push(base);
						}
			}
			closures.set(name, result);
		}
		return result;
	}
}
