package compiler.semantic;

import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstProgram;

/**
 * Module-level `var` and `final` declarations are static fields of the module's class: the class named like the module (its
 * file name), declared by the module or made for them. A module-level function `pack.Mod.f` is named as a static method of that
 * class would be, so the fields share its namespace: `x` from the module's functions, `Mod.x` after `import pack.Mod`, and
 * `import pack.Mod.x`. Everything after parsing (typing, `final` rules, globals, initialization order) sees ordinary static
 * fields. The program keeps the list, for the names the module's code may use unqualified.
 */
class ModuleFields {
	public static function fold(program:AstProgram, moduleName:String):AstProgram {
		if (program.fields == null || program.fields.length == 0)
			return program;
		var className = moduleName.substr(moduleName.lastIndexOf(".") + 1),
			classes:Array<AstClass> = [],
			folded = false;
		for (declaration in program.classes)
			if (declaration.name == className && !folded) {
				folded = true;
				classes.push({
					name: declaration.name,
					isStruct: declaration.isStruct,
					isExtern: declaration.isExtern,
					typeParameters: declaration.typeParameters,
					typeConstraints: declaration.typeConstraints,
					isPrivate: declaration.isPrivate,
					metadata: declaration.metadata,
					base: declaration.base,
					interfaces: declaration.interfaces,
					fields: declaration.fields.concat(program.fields),
					methods: declaration.methods,
					span: declaration.span
				});
			} else
				classes.push(declaration);
		if (!folded)
			classes.push({
				name: className,
				typeParameters: [],
				isPrivate: false,
				metadata: [],
				base: null,
				interfaces: [],
				fields: program.fields.copy(),
				methods: [],
				span: program.fields[0].span
			});
		return {
			packageName: program.packageName,
			imports: program.imports,
			aliases: program.aliases,
			enums: program.enums,
			enumAbstracts: program.enumAbstracts,
			abstracts: program.abstracts,
			interfaces: program.interfaces,
			classes: classes,
			functions: program.functions,
			// Kept for their names: the module's code refers to them unqualified, as to its functions (SemanticAssembly).
			fields: program.fields
		};
	}
}
