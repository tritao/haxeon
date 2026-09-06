package compiler.semantic;

import compiler.syntax.Ast;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstStatement;

/** Canonicalizes module-relative syntax into compiler-wide declaration names. */
class ModuleCanonicalizer {
	public static function canonicalFunction(fn:AstFunction, module:String, entry:String, locals:Map<String, Bool>, ?explicitName:String,
			?aliases:Map<String, String>):AstFunction {
		var name = explicitName != null ? explicitName : module == entry && fn.name == "main" ? "main" : module + "." + fn.name,
			functionAliases = aliases == null ? null : copyAliases(aliases),
			typeParameters = fn.typeParameters;
		if (functionAliases != null && typeParameters != null)
			for (parameter in typeParameters)
				functionAliases.set(parameter, parameter);
		return {
			name: name,
			isStatic: fn.isStatic,
			isExtern: fn.isExtern,
			metadata: fn.metadata,
			typeParameters: fn.typeParameters,
			typeConstraints: fn.typeConstraints == null ? null : [
				for (constraint in fn.typeConstraints)
					{
						parameter: constraint.parameter,
						type: canonicalType(constraint.type, functionAliases, fn.typeParameters),
						span: constraint.span
					}
			],
			arguments: [
				for (argument in fn.arguments)
					{
						name: argument.name,
						type: canonicalType(argument.type, functionAliases, fn.typeParameters),
						span: argument.span,
						optional: argument.optional,
						defaultValue: canonicalOptionalExpression(argument.defaultValue, module, entry, locals, functionAliases)
					}
			],
			result: canonicalType(fn.result, functionAliases, fn.typeParameters),
			span: fn.span,
			statements: [
				for (s in fn.statements)
					canonicalStatement(s, module, entry, locals, functionAliases)
			]
		};
	}

	static function copyAliases(aliases:Map<String, String>):Map<String, String>
		return [for (name => target in aliases) name => target];

	static function combinedTypeParameters(owner:Array<String>, member:Null<Array<String>>):Array<String> {
		var result = owner.copy();
		if (member != null)
			for (parameter in member)
				result.push(parameter);
		return result;
	}

	public static function canonicalName(module:String, entry:String, local:String):String
		return module == entry && local == "main" ? "main" : local.indexOf(".") >= 0 ? local : module + "." + local;

	public static function qualifiedTypeName(packageName:Null<String>, name:String):String
		return packageName == null || packageName.length == 0 ? name : packageName + "." + name;

	public static function sourceDeclarationPath(moduleName:String, declarationName:String):String {
		var primaryName = compiler.QualifiedName.last(moduleName);
		return primaryName == declarationName ? moduleName : moduleName + "." + declarationName;
	}

	public static function addDeclaredTypeAliases(aliases:Map<String, String>, program:compiler.syntax.Ast.AstProgram, packageName:Null<String>):Void {
		for (alias in program.aliases)
			aliases.set(alias.name, qualifiedTypeName(packageName, alias.name));
		for (enumDecl in program.enums)
			aliases.set(enumDecl.name, qualifiedTypeName(packageName, enumDecl.name));
		for (abstractDecl in program.enumAbstracts)
			aliases.set(abstractDecl.name, qualifiedTypeName(packageName, abstractDecl.name));
		for (abstractDecl in program.abstracts)
			aliases.set(abstractDecl.name, qualifiedTypeName(packageName, abstractDecl.name));
		for (interfaceDecl in program.interfaces)
			aliases.set(interfaceDecl.name, qualifiedTypeName(packageName, interfaceDecl.name));
		for (classDecl in program.classes)
			aliases.set(classDecl.name, qualifiedTypeName(packageName, classDecl.name));
	}

	public static function canonicalAlias(alias:compiler.syntax.Ast.AstTypeAlias, aliases:Map<String, String>,
			packageName:Null<String>):compiler.syntax.Ast.AstTypeAlias
		return {
			name: qualifiedTypeName(packageName, alias.name),
			typeParameters: alias.typeParameters,
			typeConstraints: canonicalConstraints(alias.typeConstraints, aliases, alias.typeParameters),
			type: canonicalType(alias.type, aliases, alias.typeParameters),
			isPrivate: alias.isPrivate,
			span: alias.span
		};

	public static function canonicalEnum(enumDecl:compiler.syntax.Ast.AstEnum, aliases:Map<String, String>,
			packageName:Null<String>):compiler.syntax.Ast.AstEnum
		return {
			name: qualifiedTypeName(packageName, enumDecl.name),
			typeParameters: enumDecl.typeParameters,
			typeConstraints: canonicalConstraints(enumDecl.typeConstraints, aliases, enumDecl.typeParameters),
			cases: [
				for (caseDecl in enumDecl.cases)
					{
						name: caseDecl.name,
						params: [
							for (param in caseDecl.params)
								{
									name: param.name,
									type: canonicalType(param.type, aliases, enumDecl.typeParameters),
									optional: param.optional,
									span: param.span
								}
						],
						span: caseDecl.span
					}
			],
			span: enumDecl.span
		};

	public static function canonicalEnumAbstract(decl:compiler.syntax.Ast.AstEnumAbstract, aliases:Map<String, String>, packageName:Null<String>,
			module:String, entry:String, locals:Map<String, Bool>):compiler.syntax.Ast.AstEnumAbstract
		return {
			name: qualifiedTypeName(packageName, decl.name),
			underlying: canonicalType(decl.underlying, aliases),
			fromTypes: [for (type in decl.fromTypes) canonicalType(type, aliases)],
			toTypes: [for (type in decl.toTypes) canonicalType(type, aliases)],
			values: [
				for (value in decl.values)
					{
						name: value.name,
						value: canonicalExpression(value.value, module, entry, locals, aliases),
						span: value.span
					}
			],
			span: decl.span
		};

	public static function canonicalAbstract(decl:compiler.syntax.Ast.AstAbstract, aliases:Map<String, String>, packageName:Null<String>, module:String,
			entry:String, locals:Map<String, Bool>):compiler.syntax.Ast.AstAbstract
		return {
			name: qualifiedTypeName(packageName, decl.name),
			isExtern: decl.isExtern,
			typeParameters: decl.typeParameters,
			typeConstraints: canonicalConstraints(decl.typeConstraints, aliases, decl.typeParameters),
			underlying: canonicalType(decl.underlying, aliases, decl.typeParameters),
			fromTypes: [for (type in decl.fromTypes) canonicalType(type, aliases, decl.typeParameters)],
			toTypes: [for (type in decl.toTypes) canonicalType(type, aliases, decl.typeParameters)],
			methods: [
				for (method in decl.methods)
					canonicalAbstractMethod(method, decl.typeParameters, module, entry, locals, method.name, aliases)
			],
			span: decl.span
		};

	static function canonicalAbstractMethod(method:AstFunction, ownerTypeParameters:Array<String>, module:String, entry:String, locals:Map<String, Bool>,
			name:String, aliases:Map<String, String>):AstFunction {
		var parameters = combinedTypeParameters(ownerTypeParameters, method.typeParameters),
			methodAliases = copyAliases(aliases);
		for (parameter in parameters)
			methodAliases.set(parameter, parameter);
		return {
			name: name,
			isStatic: method.isStatic,
			isExtern: method.isExtern,
			metadata: method.metadata,
			typeParameters: method.typeParameters,
			typeConstraints: method.typeConstraints == null ? null : [
				for (constraint in method.typeConstraints)
					{
						parameter: constraint.parameter,
						type: canonicalType(constraint.type, methodAliases, parameters),
						span: constraint.span
					}
			],
			arguments: [
				for (argument in method.arguments)
					{
						name: argument.name,
						type: canonicalType(argument.type, methodAliases, parameters),
						span: argument.span,
						optional: argument.optional,
						defaultValue: canonicalOptionalExpression(argument.defaultValue, module, entry, locals, methodAliases)
					}
			],
			result: canonicalType(method.result, methodAliases, parameters),
			span: method.span,
			statements: [
				for (statement in method.statements)
					canonicalStatement(statement, module, entry, locals, methodAliases)
			]
		};
	}

	public static function canonicalInterface(interfaceDecl:compiler.syntax.Ast.AstInterface, aliases:Map<String, String>,
			packageName:Null<String>):compiler.syntax.Ast.AstInterface
		return {
			name: qualifiedTypeName(packageName, interfaceDecl.name),
			typeParameters: interfaceDecl.typeParameters,
			typeConstraints: canonicalConstraints(interfaceDecl.typeConstraints, aliases, interfaceDecl.typeParameters),
			bases: [
				for (base in interfaceDecl.bases)
					canonicalType(base, aliases, interfaceDecl.typeParameters)
			],
			methods: [
				for (method in interfaceDecl.methods)
					{
						name: method.name,
						isStatic: false,
						typeParameters: method.typeParameters,
						typeConstraints: method.typeConstraints == null ? null : [
							for (constraint in method.typeConstraints)
								{
									parameter: constraint.parameter,
									type: canonicalType(constraint.type, aliases, combinedTypeParameters(interfaceDecl.typeParameters, method.typeParameters)),
									span: constraint.span
								}
						],
						arguments: [
							for (argument in method.arguments)
								{
									name: argument.name,
									type: canonicalType(argument.type, aliases, combinedTypeParameters(interfaceDecl.typeParameters, method.typeParameters)),
									span: argument.span
								}
						],
						result: canonicalType(method.result, aliases, combinedTypeParameters(interfaceDecl.typeParameters, method.typeParameters)),
						statements: [],
						span: method.span
					}
			],
			span: interfaceDecl.span
		};

	static function canonicalConstraints(constraints:Null<Array<compiler.syntax.Ast.AstTypeConstraint>>, aliases:Map<String, String>,
			typeParameters:Array<String>):Null<Array<compiler.syntax.Ast.AstTypeConstraint>>
		return constraints == null ? null : [
			for (constraint in constraints)
				{
					parameter: constraint.parameter,
					type: canonicalType(constraint.type, aliases, typeParameters),
					span: constraint.span
				}
		];

	public static function astTypeName(type:compiler.syntax.Ast.AstType):String
		return switch type {
			case IntType: "Int";
			case BoolType: "Bool";
			case FloatType: "Float";
			case StringType: "String";
			case VoidType: "Void";
			case InferredType: "_";
			case NativeAbstractType(name): 'hl.Abstract<"$name">';
			case NamedType(name): name;
			case AppliedType(name, arguments): '$name<${[for (argument in arguments) astTypeName(argument)].join(",")}>';
			case ArrayType(element): 'Array<${astTypeName(element)}>';
			case MapType(key, value): 'Map<${astTypeName(key)},${astTypeName(value)}>';
			case NullableType(element): 'Null<${astTypeName(element)}>';
			case FunctionType(arguments, result): '(' + [for (argument in arguments) astTypeName(argument)].join(',') + ')->' + astTypeName(result);
			case AnonymousType(fields): '{' + [
					for (field in fields)
						(field.optional ? "?" : "") + field.name + ":" + astTypeName(field.type)
				].join(',') + '}';
		};

	public static function canonicalStatement(s:AstStatement, module:String, entry:String, locals:Map<String, Bool>, ?aliases:Map<String, String>):AstStatement
		return switch s {
			case UninitializedDeclaration(n, t, span): UninitializedDeclaration(n, canonicalType(t, aliases), span);
			case VarDeclaration(n, t, e,
				span): VarDeclaration(n, t == null ? null : canonicalType(t, aliases), canonicalExpression(e, module, entry, locals, aliases), span);
			case Assignment(n, e, span): Assignment(n, canonicalExpression(e, module, entry, locals, aliases), span);
			case IndexAssignment(array, offset, e,
				span): IndexAssignment(canonicalExpression(array, module, entry, locals, aliases),
					canonicalExpression(offset, module, entry, locals, aliases), canonicalExpression(e, module, entry, locals, aliases), span);
			case FieldAssignment(object, field, e,
				span): FieldAssignment(canonicalExpression(object, module, entry, locals, aliases), field,
					canonicalExpression(e, module, entry, locals, aliases), span);
			case Return(e, span): Return(canonicalExpression(e, module, entry, locals, aliases), span);
			case Throw(e, span): Throw(canonicalExpression(e, module, entry, locals, aliases), span);
			case Try(tryBranch, catches, span): Try([for (x in tryBranch) canonicalStatement(x, module, entry, locals, aliases)], [
					for (catchClause in catches)
						{
							name: catchClause.name,
							type: canonicalType(catchClause.type, aliases),
							statements: [
								for (x in catchClause.statements)
									canonicalStatement(x, module, entry, locals, aliases)
							],
							span: catchClause.span
						}
				], span);
			case ReturnVoid(span): ReturnVoid(span);
			case Break(span): Break(span);
			case Continue(span): Continue(span);
			case Increment(name, delta, span): Increment(name, delta, span);
			case If(c, y, n,
				span): If(canonicalExpression(c, module, entry, locals, aliases), [for (x in y) canonicalStatement(x, module, entry, locals, aliases)],
					[for (x in n) canonicalStatement(x, module, entry, locals, aliases)], span);
			case While(c, b,
				span): While(canonicalExpression(c, module, entry, locals, aliases), [for (x in b) canonicalStatement(x, module, entry, locals, aliases)],
					span);
			case DoWhile(b, c,
				span): DoWhile([for (x in b) canonicalStatement(x, module, entry, locals, aliases)], canonicalExpression(c, module, entry, locals, aliases),
					span);
			case ForIn(name, valueName, iterable, body,
				span): ForIn(name, valueName, canonicalExpression(iterable, module, entry, locals, aliases),
					[for (x in body) canonicalStatement(x, module, entry, locals, aliases)], span);
			case Switch(expression, cases, defaultBranch, hasDefault, span):
				Switch(canonicalExpression(expression, module, entry, locals, aliases), [
					for (switchCase in cases)
						{
							value: canonicalExpression(switchCase.value, module, entry, locals, aliases),
							guard: canonicalOptionalExpression(switchCase.guard, module, entry, locals, aliases),
							statements: [
								for (x in switchCase.statements)
									canonicalStatement(x, module, entry, locals, aliases)
							],
							span: switchCase.span
						}
				],
					[for (x in defaultBranch) canonicalStatement(x, module, entry, locals, aliases)], hasDefault, span);
			case Expression(e, span): Expression(canonicalExpression(e, module, entry, locals, aliases), span);
		}

	public static function canonicalExpression(e:AstExpression, module:String, entry:String, locals:Map<String, Bool>,
			?aliases:Map<String, String>):AstExpression
		return switch e {
			case IntegerLiteral(_, _), FloatLiteral(_, _), StringLiteral(_, _), BoolLiteral(_, _), NullLiteral(_), Unreachable(_): e;
			case Variable(name, span):
				var dot = name.indexOf("."),
					prefix = compiler.QualifiedName.first(name),
					imported:Null<String> = null;
				if (!locals.exists(prefix))
					imported = resolveOptionalExpressionAlias(name, aliases);
				if (imported != null) Variable(imported,
					span); else if (dot < 0 && locals.exists(name)) Variable(module == entry
					&& name == "main" ? "main" : module + "." + name, span); else e;
			case Member(object, name, s): Member(canonicalExpression(object, module, entry, locals, aliases), name, s);
			case Add(a, b, s): Add(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case Sub(a, b, s): Sub(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case Mul(a, b, s): Mul(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case Div(a, b, s): Div(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case Mod(a, b, s): Mod(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case BitAnd(a, b, s): BitAnd(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case BitXor(a, b, s): BitXor(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case BitOr(a, b, s): BitOr(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case ShiftLeft(a, b,
				s): ShiftLeft(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case ShiftRight(a, b,
				s): ShiftRight(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case UnsignedShiftRight(a, b, s):
				UnsignedShiftRight(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case Negate(value, s): Negate(canonicalExpression(value, module, entry, locals, aliases), s);
			case Less(a, b, s): Less(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case LessEqual(a, b,
				s): LessEqual(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case Greater(a, b, s): Greater(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case GreaterEqual(a, b,
				s): GreaterEqual(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case Equal(a, b, s): Equal(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case NotEqual(a, b, s): NotEqual(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case Not(value, s): Not(canonicalExpression(value, module, entry, locals, aliases), s);
			case And(a, b, s): And(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case Or(a, b, s): Or(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case Conditional(predicate, whenTrue, whenFalse, s):
				Conditional(canonicalExpression(predicate, module, entry, locals, aliases), canonicalExpression(whenTrue, module, entry, locals, aliases),
					canonicalExpression(whenFalse, module, entry, locals, aliases), s);
			case BlockExpression(statements, value, s):
				BlockExpression([
					for (statement in statements)
						canonicalStatement(statement, module, entry, locals, aliases)
				], canonicalExpression(value, module, entry, locals, aliases), s);
			case ThrowExpression(value, s): ThrowExpression(canonicalExpression(value, module, entry, locals, aliases), s);
			case Cast(value, target, s):
				Cast(canonicalExpression(value, module, entry, locals, aliases), canonicalOptionalType(target, aliases), s);
			case SwitchExpression(subject, cases, fallback, s):
				SwitchExpression(canonicalExpression(subject, module, entry, locals, aliases), [
					for (switchCase in cases)
						{
							value: canonicalExpression(switchCase.value, module, entry, locals, aliases),
							guard: canonicalOptionalExpression(switchCase.guard, module, entry, locals, aliases),
							result: canonicalExpression(switchCase.result, module, entry, locals, aliases),
							span: switchCase.span
						}
				], canonicalOptionalExpression(fallback, module, entry, locals, aliases), s);
			case ObjectLiteral(fields, s): ObjectLiteral([
					for (field in fields)
						{name: field.name, value: canonicalExpression(field.value, module, entry, locals, aliases), span: field.span}
				], s);
			case ArrayLiteral(values, s): ArrayLiteral([for (value in values) canonicalExpression(value, module, entry, locals, aliases)], s);
			case MapLiteral(entries, s): MapLiteral([
					for (mapEntry in entries)
						{
							key: canonicalExpression(mapEntry.key, module, entry, locals, aliases),
							value: canonicalExpression(mapEntry.value, module, entry, locals, aliases),
							span: mapEntry.span
						}
				], s);
			case ArrayComprehension(keyName, valueName, iterable, predicate, value, s):
				ArrayComprehension(keyName, valueName, canonicalExpression(iterable, module, entry, locals, aliases),
					canonicalOptionalExpression(predicate, module, entry, locals, aliases), canonicalExpression(value, module, entry, locals, aliases), s);
			case MapComprehension(keyName, valueName, iterable, predicate, key, value, s):
				MapComprehension(keyName, valueName, canonicalExpression(iterable, module, entry, locals, aliases),
					canonicalOptionalExpression(predicate, module, entry, locals, aliases), canonicalExpression(key, module, entry, locals, aliases),
					canonicalExpression(value, module, entry, locals, aliases), s);
			case Range(start, rangeEnd,
				s): Range(canonicalExpression(start, module, entry, locals, aliases), canonicalExpression(rangeEnd, module, entry, locals, aliases), s);
			case Call(name, args, s):
				var resolved = name;
				var dot = name.indexOf("."),
					prefix = compiler.QualifiedName.first(name),
					imported = resolveOptionalExpressionAlias(name, aliases);
				if (imported != null)
					resolved = imported;
				else if (name.indexOf(".") < 0 && locals.exists(name))
					resolved = module == entry && name == "main" ? "main" : module + "." + name;
				Call(resolved, [for (a in args) canonicalExpression(a, module, entry, locals, aliases)], s);
			case MethodCall(object, name, args,
				s): MethodCall(canonicalExpression(object, module, entry, locals, aliases), name,
					[for (a in args) canonicalExpression(a, module, entry, locals, aliases)], s);
			case New(typeName, args, s): New(resolveTypeName(typeName, aliases), [for (a in args) canonicalExpression(a, module, entry, locals, aliases)], s);
			case NewGeneric(typeName, typeArguments, args, s):
				NewGeneric(resolveTypeName(typeName, aliases), [for (type in typeArguments) canonicalType(type, aliases)],
					[for (a in args) canonicalExpression(a, module, entry, locals, aliases)], s);
			case NewArray(element, length, s): NewArray(canonicalType(element, aliases), canonicalExpression(length, module, entry, locals, aliases), s);
			case NewMap(key, value, s): NewMap(canonicalType(key, aliases), canonicalType(value, aliases), s);
			case Index(array, offset,
				s): Index(canonicalExpression(array, module, entry, locals, aliases), canonicalExpression(offset, module, entry, locals, aliases), s);
			case PostfixIncrement(target, delta, s): PostfixIncrement(canonicalExpression(target, module, entry, locals, aliases), delta, s);
			case Lambda(arguments, body, s):
				Lambda([
					for (argument in arguments)
						{
							name: argument.name,
							type: canonicalType(argument.type, aliases),
							span: argument.span
						}
				], [
					for (statement in body)
						canonicalStatement(statement, module, entry, locals, aliases)
				], s);
		}

	public static function canonicalOptionalExpression(e:Null<AstExpression>, module:String, entry:String, locals:Map<String, Bool>,
			aliases:Null<Map<String, String>>):Null<AstExpression> {
		if (e == null)
			return null;
		return canonicalExpression(e, module, entry, locals, aliases);
	}

	public static function canonicalOptionalType(type:Null<compiler.syntax.Ast.AstType>, aliases:Null<Map<String, String>>):Null<compiler.syntax.Ast.AstType> {
		if (type == null)
			return null;
		return canonicalType(type, aliases);
	}

	public static function resolveTypeName(name:String, aliases:Null<Map<String, String>>):String {
		if (aliases == null)
			return name;
		var availableAliases:Map<String, String> = aliases;
		if (!availableAliases.exists(name))
			return name;
		return availableAliases.get(name);
	}

	public static function resolveOptionalTypeName(name:Null<String>, aliases:Null<Map<String, String>>):Null<String> {
		if (name == null)
			return null;
		return resolveTypeName(name, aliases);
	}

	public static function resolveExpressionAlias(name:String, aliases:Map<String, String>):Null<String> {
		var candidate = name;
		while (true) {
			if (aliases.exists(candidate)) {
				var resolved = aliases.get(candidate),
					suffix = name.substring(candidate.length, name.length);
				return resolved + suffix;
			}
			var parent = compiler.QualifiedName.parentOrEmpty(candidate);
			if (parent.length == 0)
				return null;
			candidate = parent;
		}
	}

	public static function resolveOptionalExpressionAlias(name:String, aliases:Null<Map<String, String>>):Null<String> {
		if (aliases == null)
			return null;
		return resolveExpressionAlias(name, aliases);
	}

	public static function canonicalType(type:compiler.syntax.Ast.AstType, aliases:Null<Map<String, String>>,
			?typeParameters:Array<String>):compiler.syntax.Ast.AstType
		return switch type {
			case NativeAbstractType(name): NativeAbstractType(name);
			case NamedType(name): NamedType(typeParameters != null
					&& typeParameters.indexOf(name) >= 0 ? name : resolveTypeName(name, aliases));
			case AppliedType(name,
				arguments): AppliedType(resolveTypeName(name, aliases), [for (argument in arguments) canonicalType(argument, aliases, typeParameters)]);
			case ArrayType(element): ArrayType(canonicalType(element, aliases, typeParameters));
			case MapType(key, value): MapType(canonicalType(key, aliases, typeParameters), canonicalType(value, aliases, typeParameters));
			case NullableType(element): NullableType(canonicalType(element, aliases, typeParameters));
			case FunctionType(arguments,
				result): FunctionType([for (argument in arguments) canonicalType(argument, aliases, typeParameters)],
					canonicalType(result, aliases, typeParameters));
			case AnonymousType(fields): AnonymousType([
					for (field in fields)
						{
							name: field.name,
							type: canonicalType(field.type, aliases, typeParameters),
							optional: field.optional,
							span: field.span
						}
				]);
			default: type;
		};
}
