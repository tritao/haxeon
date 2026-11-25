package compiler.semantic;

import compiler.syntax.Ast.AstProgram;
import compiler.syntax.Ast.AstVisibility;

/**
 * Module-level `var` and `final` declarations are members of their module, as its functions are: `x` in the module's code,
 * `Mod.x` after `import pack.Mod`, and `import pack.Mod.x`. Like Haxe (which keeps them in a `Mod_Fields_` class), Haxeon
 * stores them as the static fields of a hidden class of the module, `pack.Mod$fields`, which no other declaration shares: a class
 * the module declares (`class Mod`) keeps its own statics, and reflection on it does not see them. Name resolution
 * (ModuleCanonicalizer, through AliasTable.moduleFieldPath) names them where they are stored, so typing, `final` rules,
 * globals and initialization order see ordinary static fields.
 */
class ModuleFields {
	static inline final SUFFIX = "$fields";

	/** The hidden class that stores the module-level variables of `moduleName`, as the module declares it. */
	public static inline function className(moduleName:String):String
		return moduleName.substr(moduleName.lastIndexOf(".") + 1) + SUFFIX;

	/** The canonical name of that class. */
	public static inline function storageName(moduleName:String):String
		return moduleName + SUFFIX;

	public static function fold(program:AstProgram, moduleName:String):AstProgram {
		if (program.fields == null || program.fields.length == 0)
			return program;
		return {
			packageName: program.packageName,
			imports: program.imports,
			usings: program.usings,
			aliases: program.aliases,
			enums: program.enums,
			abstracts: program.abstracts,
			interfaces: program.interfaces,
			classes: program.classes.concat([
				{
					name: className(moduleName),
					typeParameters: [],
					visibility: AstVisibility.Unwritten,
					metadata: [],
					base: null,
					interfaces: [],
					fields: program.fields.copy(),
					methods: [],
					span: program.fields[0].span
				}
			]),
			functions: program.functions,
			// Kept for their names: the module's code refers to them unqualified, as to its functions (SemanticAssembly).
			fields: program.fields
		};
	}
}
