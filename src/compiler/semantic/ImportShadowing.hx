package compiler.semantic;

import compiler.AmbiguousName;
import compiler.syntax.Ast.AstProgram;

/**
 * A type that a module or wildcard import brings in only as a side effect must not silently replace a type of the same name
 * that the current package declares. Haxe resolves such a name to the import; a module that also uses its own package's type
 * then type-checks against the wrong one, often with an implicit or unchecked conversion hiding the mix-up.
 *
 * Such a name resolves to a marker that records both candidates. A marker matches no declaration, so a use of the name fails
 * whichever check first rejects it, at the use's own span, and `Diagnostic` turns that diagnostic into E1029 (`AmbiguousName.describe`). A
 * name the module never uses is never reported. Importing a type by name (`import a.B;`, `import a.B as C;`) is a deliberate choice
 * and still shadows, as do the module's own declarations.
 */
class ImportShadowing {
	/** The names `importedTypes` would silently take from `packageTypes`, each mapped to its marker. */
	public static function ambiguousNames(ast:AstProgram, importedTypes:Map<String, String>, packageTypes:Map<String, String>):Map<String, String> {
		var named:Map<String, Bool> = [], result:Map<String, String> = [];
		for (path in ast.imports)
			if (!ModuleAnalyzer.isWildcardImport(path))
				named.set(QualifiedName.last(path), true);
		for (alias in ast.importAliases.keys())
			named.set(alias, true);
		for (name in declaredNames(ast))
			named.set(name, true);
		for (name => imported in importedTypes) {
			if (name.indexOf(".") >= 0 || named.exists(name))
				continue;
			var own = packageTypes.get(name);
			if (own != null && own != imported)
				result.set(name, AmbiguousName.marker(name, own, imported));
		}
		return result;
	}

	static function declaredNames(ast:AstProgram):Array<String> {
		var names:Array<String> = [];
		for (declaration in ast.classes)
			names.push(QualifiedName.last(declaration.name));
		for (declaration in ast.interfaces)
			names.push(QualifiedName.last(declaration.name));
		for (declaration in ast.enums)
			names.push(QualifiedName.last(declaration.name));
		for (declaration in ast.enumAbstracts)
			names.push(QualifiedName.last(declaration.name));
		for (declaration in ast.abstracts)
			names.push(QualifiedName.last(declaration.name));
		for (declaration in ast.aliases)
			names.push(QualifiedName.last(declaration.name));
		return names;
	}
}
