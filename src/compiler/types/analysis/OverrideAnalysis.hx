package compiler.types.analysis;

import compiler.syntax.Ast;

/** Instance methods that some subclass overrides; a call through the base may reach another body. */
class OverrideAnalysis {
	public static function overriddenMethods(classes:Map<String, AstClass>):Map<String, Bool> {
		var result:Map<String, Bool> = [];
		for (className => classDecl in classes) {
			var ancestors:Array<String> = [],
				seen:Map<String, Bool> = [className => true],
				current = classDecl;
			while (current != null && current.base != null) {
				var baseName = inheritanceName(current.base);
				if (baseName == null || seen.exists(baseName))
					break;
				seen.set(baseName, true);
				ancestors.push(baseName);
				current = classes.get(baseName);
			}
			for (method in classDecl.methods)
				if (!method.isStatic && method.name != "new")
					for (ancestor in ancestors)
						result.set(ancestor + "." + method.name, true);
		}
		return result;
	}

	static function inheritanceName(type:AstType):Null<String>
		return switch type {
			case NamedType(name), AppliedType(name, _): name;
			default: null;
		};

	/** Direct subclasses of every class, the inverse of `AstClass.base`. */
	public static function childrenOf(classes:Map<String, AstClass>):Map<String, Array<String>> {
		var result:Map<String, Array<String>> = [];
		for (className => classDecl in classes) {
			var baseName = classDecl.base == null ? null : inheritanceName(classDecl.base);
			if (baseName == null)
				continue;
			var siblings = result.get(baseName);
			if (siblings == null) {
				siblings = [];
				result.set(baseName, siblings);
			}
			siblings.push(className);
		}
		return result;
	}

	/** Every concrete body, anywhere in `owner`'s descendant tree, that redeclares `method` -
	 * exactly the bodies a virtual call through `owner.method` could also reach at runtime.
	 */
	public static function overridingMethods(children:Map<String, Array<String>>, classes:Map<String, AstClass>, owner:String, method:String):Array<String> {
		var result:Array<String> = [], worklist = children.get(owner);
		if (worklist == null)
			return result;
		worklist = worklist.copy();
		while (worklist.length > 0) {
			var child = worklist.pop();
			var classDecl = classes.get(child);
			if (classDecl == null)
				continue;
			var declares = false;
			for (method2 in classDecl.methods)
				if (!method2.isStatic && method2.name == method) {
					declares = true;
					break;
				}
			if (declares)
				result.push(child + "." + method);
			var grandchildren = children.get(child);
			if (grandchildren != null)
				for (grandchild in grandchildren)
					worklist.push(grandchild);
		}
		return result;
	}

	/** For every method key some subclass overrides, the concrete override bodies required to
	 * ALSO share an answer before that key's own answer can be trusted through a virtual call.
	 */
	public static function overrideFamilies(classes:Map<String, AstClass>, overridden:Map<String, Bool>):Map<String, Array<String>> {
		var children = childrenOf(classes),
			result:Map<String, Array<String>> = [];
		for (key in overridden.keys()) {
			var dot = key.lastIndexOf(".");
			if (dot < 0)
				continue;
			var owner = key.substr(0, dot),
				method = key.substr(dot + 1),
				ownerDecl = classes.get(owner);
			if (ownerDecl == null)
				continue;
			var declaresOwnBody = false;
			for (method2 in ownerDecl.methods)
				if (!method2.isStatic && method2.name == method) {
					declaresOwnBody = true;
					break;
				}
			if (!declaresOwnBody)
				continue;
			result.set(key, overridingMethods(children, classes, owner, method));
		}
		return result;
	}
}
