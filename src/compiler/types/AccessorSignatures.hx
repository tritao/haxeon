package compiler.types;

import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstField;
import compiler.syntax.Ast.AstFieldAccess;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstProgram;
import compiler.syntax.AstFunctions;

/**
 * Haxe's rule for property accessors: an unannotated `get_x` returns, and an unannotated `set_x` takes and returns, the declared
 * type of property `x`. It is a declared rule, not an inference from the body, so it is applied to the syntax before anything is
 * typed, as an annotation would be (docs/design/LAZY_DECLARATION_TYPING.md, semantics 7).
 */
class AccessorSignatures {
	/** `program` with each unannotated accessor of an annotated property given the property's type. */
	public static function withPropertyTypes(program:AstProgram):AstProgram {
		var changed = false;
		var classes = [for (classDecl in program.classes) {
			var withTypes = classWithPropertyTypes(classDecl);
			if (withTypes != classDecl)
				changed = true;
			withTypes;
		}];
		return !changed ? program : {
			packageName: program.packageName,
			imports: program.imports,
			usings: program.usings,
			aliases: program.aliases,
			enums: program.enums,
			enumAbstracts: program.enumAbstracts,
			abstracts: program.abstracts,
			interfaces: program.interfaces,
			classes: classes,
			functions: program.functions
		};
	}

	static function classWithPropertyTypes(classDecl:AstClass):AstClass {
		var changed = false;
		var methods = [for (method in classDecl.methods) {
			var withType = accessorWithPropertyType(method, classDecl.fields);
			if (withType != method)
				changed = true;
			withType;
		}];
		return !changed ? classDecl : {
			name: classDecl.name,
			isStruct: classDecl.isStruct,
			isExtern: classDecl.isExtern,
			typeParameters: classDecl.typeParameters,
			typeConstraints: classDecl.typeConstraints,
			isPrivate: classDecl.isPrivate,
			metadata: classDecl.metadata,
			base: classDecl.base,
			interfaces: classDecl.interfaces,
			fields: classDecl.fields,
			methods: methods,
			span: classDecl.span
		};
	}

	static function accessorWithPropertyType(method:AstFunction, fields:Array<AstField>):AstFunction {
		var isGetter = StringTools.startsWith(method.name, "get_"),
			isSetter = StringTools.startsWith(method.name, "set_");
		if (!isGetter && !isSetter)
			return method;
		var propertyName = method.name.substring(4),
			propertyType:Null<compiler.syntax.Ast.AstType> = null;
		for (field in fields)
			if (field.name == propertyName
				&& field.type != null
				&& field.isStatic == method.isStatic
				&& (isGetter ? field.readAccess == AstFieldAccess.GetAccess : field.writeAccess
				== AstFieldAccess.SetAccess))
				propertyType = field.type;
		if (propertyType == null || (isSetter ? method.arguments.length != 1 : method.arguments.length != 0))
			return method;
		var arguments = method.arguments, changed = false;
		if (isSetter && AstFunctions.isInferred(arguments[0].type)) {
			changed = true;
			var argument = arguments[0];
			arguments = [
				{
					name: argument.name,
					type: propertyType,
					span: argument.span,
					optional: argument.optional,
					defaultValue: argument.defaultValue
				}
			];
		}
		var resultInferred = AstFunctions.isInferred(method.result);
		if (!changed && !resultInferred)
			return method;
		var result = resultInferred ? propertyType : method.result;
		return AstFunctions.withSignature(method, method.name, method.typeConstraints, arguments, result,
			method.statements);
	}
}
