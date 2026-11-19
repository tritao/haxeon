package compiler.ir;

import compiler.ir.Ir.IrInterface;
import compiler.ir.Ir.IrObject;
import compiler.ir.Ir.IrProgram;

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
	final implementors:Map<String, Array<IrObject>> = [];

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
		var result = implementors.get(interfaceName);
		if (result == null) {
			result = [
				for (object in program.objects)
					if (implementsInterface(object.name, interfaceName)) object
			];
			implementors.set(interfaceName, result);
		}
		return result;
	}
}
