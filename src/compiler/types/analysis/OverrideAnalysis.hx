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
}
