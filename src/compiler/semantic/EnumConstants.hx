package compiler.semantic;

import compiler.syntax.Ast.AstEnum;
import compiler.syntax.Ast.AstEnumConstant;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstProgram;
import compiler.syntax.Ast.AstSwitchExpressionCase;

/**
 * An enum's per-case constants (`final componentCount:Int;`, set by each case: `Float {componentCount: 1}`). Each becomes an
 * inline instance method of the enum whose body is `switch this` over its cases, so a read (`value.componentCount`) is a call
 * of it that inlining folds where the case is known, and no IR is new (docs/design/ENUM_MEMBERS.md). The getter's name cannot be
 * written in source, so the constant reads as a field and nothing calls it as a method. The declaration keeps its constants for
 * the checks (`ProgramTyper`) and the API model.
 */
class EnumConstants {
	static inline final SUFFIX = "$constant";

	/** The method that reads the per-case constant `name`. */
	public static inline function getterName(name:String):String
		return name + SUFFIX;

	/** Whether `method` is a per-case constant's getter. */
	public static inline function isGetter(method:String):Bool
		return StringTools.endsWith(method, SUFFIX);

	/** The constant whose getter is `method`, or null when it is no getter. */
	public static function constantOf(method:String):Null<String>
		return isGetter(method) ? method.substr(0, method.length - SUFFIX.length) : null;

	/** The constant `name` that `enumDecl` declares, or null. */
	public static function declared(enumDecl:AstEnum, name:String):Null<AstEnumConstant> {
		if (enumDecl.constants != null)
			for (constant in enumDecl.constants)
				if (constant.name == name)
					return constant;
		return null;
	}

	/** `program` with each enum's per-case constants given their getters. */
	public static function fold(program:AstProgram):AstProgram {
		var any = false;
		for (declaration in program.enums)
			if (declaration.constants != null && declaration.constants.length > 0)
				any = true;
		if (!any)
			return program;
		return {
			packageName: program.packageName,
			imports: program.imports,
			usings: program.usings,
			aliases: program.aliases,
			enums: [for (declaration in program.enums) withGetters(declaration)],
			abstracts: program.abstracts,
			interfaces: program.interfaces,
			classes: program.classes,
			functions: program.functions,
			fields: program.fields
		};
	}

	static function withGetters(declaration:AstEnum):AstEnum {
		if (declaration.constants == null || declaration.constants.length == 0)
			return declaration;
		var methods = (declaration.methods ?? []).copy();
		for (constant in declaration.constants)
			methods.push(getter(declaration, constant));
		return {
			name: declaration.name,
			visibility: declaration.visibility,
			typeParameters: declaration.typeParameters,
			typeConstraints: declaration.typeConstraints,
			conformances: declaration.conformances,
			methods: methods,
			fields: declaration.fields,
			constants: declaration.constants,
			metadata: declaration.metadata,
			cases: declaration.cases,
			span: declaration.span
		};
	}

	/**
	 * `switch this { case A: a; case B(_, _): b; }`: each case's value, or the default for a case that sets none. A case missing a
	 * value it needs, which `ProgramTyper` reports, reads the type's default here so the getter still types.
	 */
	static function getter(declaration:AstEnum, constant:AstEnumConstant):AstFunction {
		var span = constant.span,
			cases:Array<AstSwitchExpressionCase> = [];
		for (constructor in declaration.cases) {
			var value = constant.defaultValue;
			if (constructor.constants != null)
				for (given in constructor.constants)
					if (given.name == constant.name)
						value = given.value;
			var pattern:AstExpression = constructor.params.length == 0 ? Variable(constructor.name,
				span) : Call(constructor.name, [for (_ in constructor.params) Variable("_", span)], span);
			cases.push({
				patterns: [pattern],
				guard: null,
				result: value ?? Unreachable(span),
				span: span
			});
		}
		return {
			visibility: constant.visibility,
			name: getterName(constant.name),
			isStatic: false,
			isInline: true,
			metadata: [],
			typeParameters: [],
			arguments: [],
			result: constant.type,
			statements: [Return(SwitchExpression(Variable("this", span), cases, null, span), span)],
			span: span
		};
	}
}
