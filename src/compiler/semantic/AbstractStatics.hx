package compiler.semantic;

import compiler.syntax.Ast.AstAbstract;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstField;
import compiler.syntax.Ast.AstProgram;

/**
 * The static variables of an abstract (`static var count = 0`, `static final step = 2`). An abstract stores nothing but its
 * underlying value, so Haxe keeps them in its implementation class (`Counter_Impl_`), with its methods. Haxeon stores them as the
 * static fields of a hidden class of the module, `pack.Counter$statics`, placed where the abstract is declared among the module's
 * classes, so typing, `final` rules, globals and initialization order (`StaticInitializationOrder`) see ordinary static fields.
 * Source names them through the abstract (`Counter.count`, `count` in its methods): `MemberAccess.classField` finds an abstract's
 * statics in its storage class, and the storage class's initializers are typed as the abstract's code (`lexicalOwner`).
 */
class AbstractStatics {
	static inline final SUFFIX = "$statics";

	/** The hidden class that stores the static variables of the abstract `abstractName` (as declared, or canonical). */
	public static inline function storageName(abstractName:String):String
		return abstractName + SUFFIX;

	/** The abstract whose statics the class `className` stores, or null when it is not such a class. */
	public static function abstractOf(className:Null<String>):Null<String>
		return className != null && StringTools.endsWith(className, SUFFIX)
			? className.substr(0, className.length - SUFFIX.length) : null;

	/** The declaration source names for the class `className`: the abstract, for its statics' storage class. */
	public static function displayOwner(className:String):String
		return abstractOf(className) ?? className;

	/**
	 * Whether `field` of an abstract is a static variable, which its storage class keeps: a stored one, or a property whose
	 * accessors are the abstract's static methods (`ClassProperties`).
	 */
	public static function isStored(field:AstField):Bool
		return field.isStatic;

	/**
	 * `program` with each abstract's stored statics moved to its storage class, which goes among the module's classes where the
	 * abstract is declared (before the first class declared after it), as Haxe orders the module's types.
	 */
	public static function fold(program:AstProgram):AstProgram {
		var storage:Array<AstClass> = [];
		var abstracts = [for (declaration in program.abstracts) {
			var stored = [for (field in declaration.fields) if (isStored(field)) field];
			if (stored.length == 0 && !Lambda.exists(declaration.methods, method -> method.isDynamic == true))
				declaration;
			else {
				storage.push(storageClass(declaration, stored));
				withFields(declaration, [for (field in declaration.fields) if (!isStored(field)) field]);
			}
		}];
		if (storage.length == 0)
			return program;
		var classes = program.classes.copy();
		for (storageClass in storage) {
			var index = 0;
			while (index < classes.length && classes[index].span.start < storageClass.span.start)
				index++;
			classes.insert(index, storageClass);
		}
		return {
			packageName: program.packageName,
			imports: program.imports,
			usings: program.usings,
			aliases: program.aliases,
			enums: program.enums,
			abstracts: abstracts,
			interfaces: program.interfaces,
			classes: classes,
			functions: program.functions,
			fields: program.fields
		};
	}

	static function storageClass(declaration:AstAbstract, fields:Array<AstField>):AstClass
		return {
			name: storageName(declaration.name),
			typeParameters: [],
			isPrivate: false,
			// The abstract's `@:allow` and `@:publicFields` are its statics' too.
			metadata: declaration.metadata == null ? [] : declaration.metadata,
			base: null,
			interfaces: [],
			fields: fields,
			methods: [],
			span: declaration.span
		};

	static function withFields(declaration:AstAbstract, fields:Array<AstField>):AstAbstract
		return {
			name: declaration.name,
			isExtern: declaration.isExtern,
			metadata: declaration.metadata,
			typeParameters: declaration.typeParameters,
			typeConstraints: declaration.typeConstraints,
			conformances: declaration.conformances,
			isInternal: declaration.isInternal,
			underlying: declaration.underlying,
			fromTypes: declaration.fromTypes,
			toTypes: declaration.toTypes,
			fields: fields,
			methods: declaration.methods,
			values: declaration.values,
			span: declaration.span
		};
}
