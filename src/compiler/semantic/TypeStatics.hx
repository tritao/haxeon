package compiler.semantic;

import compiler.syntax.Ast.AstAbstract;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstEnum;
import compiler.syntax.Ast.AstField;
import compiler.syntax.Ast.AstProgram;
import compiler.syntax.Ast.AstVisibility;

/**
 * The static variables of an abstract or an enum (`static var count = 0`, `static final ALL = [A, B]`). Neither stores
 * anything but its value, so Haxe keeps an abstract's in its implementation class (`Counter_Impl_`). Haxeon stores them as the
 * static fields of a hidden class of the module, `pack.Counter$statics`, placed where the type is declared among the module's
 * classes, so typing, `final` rules, globals and initialization order (`StaticInitializationOrder`) see ordinary static fields.
 * Source names them through the type (`Counter.count`, `count` in its methods): `MemberAccess.classField` finds them in the
 * storage class, and the storage class's initializers are typed as the type's code (`lexicalOwner`).
 */
class TypeStatics {
	static inline final SUFFIX = "$statics";

	/** The hidden class that stores the static variables of the abstract or enum `typeName` (as declared, or canonical). */
	public static inline function storageName(typeName:String):String
		return typeName + SUFFIX;

	/** The abstract or enum whose statics the class `className` stores, or null when it is not such a class. */
	public static function ownerOf(className:Null<String>):Null<String>
		return className != null && StringTools.endsWith(className, SUFFIX)
			? className.substr(0, className.length - SUFFIX.length) : null;

	/** The declaration source names for the class `className`: the abstract or enum, for its statics' storage class. */
	public static function displayOwner(className:String):String
		return ownerOf(className) ?? className;

	/**
	 * Whether `field` of an abstract is a static variable, which its storage class keeps: a stored one, or a property whose
	 * accessors are the abstract's static methods (`ClassProperties`).
	 */
	public static function isStored(field:AstField):Bool
		return field.isStatic;

	/**
	 * `program` with each abstract's and enum's stored statics moved to its storage class, which goes among the module's classes
	 * where the type is declared (before the first class declared after it), as Haxe orders the module's types.
	 */
	public static function fold(program:AstProgram):AstProgram {
		var storage:Array<AstClass> = [];
		var enums = [for (declaration in program.enums)
			if (declaration.fields == null || declaration.fields.length == 0)
			declaration
			else {
				storage.push(storageClass(declaration.name, declaration.metadata, declaration.fields,
					declaration.span));
				withoutFields(declaration);
			}];
		var abstracts = [for (declaration in program.abstracts) {
			var stored = [for (field in declaration.fields) if (isStored(field)) field];
			if (stored.length == 0 && !Lambda.exists(declaration.methods, method -> method.isDynamic == true))
				declaration;
			else {
				storage.push(storageClass(declaration.name, declaration.metadata, stored, declaration.span));
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
			enums: enums,
			abstracts: abstracts,
			interfaces: program.interfaces,
			classes: classes,
			functions: program.functions,
			fields: program.fields
		};
	}

	static function storageClass(typeName:String, metadata:Null<Array<compiler.syntax.Ast.AstMetadata>>,
			fields:Array<AstField>, span:compiler.core.Source.SourceSpan):AstClass
		return {
			name: storageName(typeName),
			typeParameters: [],
			visibility: AstVisibility.Unwritten,
			// The type's `@:allow` and `@:publicFields` are its statics' too.
			metadata: metadata == null ? [] : metadata,
			base: null,
			interfaces: [],
			fields: fields,
			methods: [],
			span: span
		};

	static function withoutFields(declaration:AstEnum):AstEnum
		return {
			name: declaration.name,
			visibility: declaration.visibility,
			typeParameters: declaration.typeParameters,
			typeConstraints: declaration.typeConstraints,
			conformances: declaration.conformances,
			methods: declaration.methods,
			fields: [],
			constants: declaration.constants,
			metadata: declaration.metadata,
			cases: declaration.cases,
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
			visibility: declaration.visibility,
			underlying: declaration.underlying,
			fromTypes: declaration.fromTypes,
			toTypes: declaration.toTypes,
			fields: fields,
			methods: declaration.methods,
			values: declaration.values,
			isRawEnum: declaration.isRawEnum,
			span: declaration.span
		};
}
