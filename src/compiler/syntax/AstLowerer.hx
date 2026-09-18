package compiler.syntax;

import compiler.syntax.Ast.AstProgram;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstInterface;
import compiler.syntax.Ast.AstTypeAlias;
import compiler.syntax.Ast.AstEnum;
import compiler.syntax.Ast.AstEnumAbstract;
import compiler.syntax.Ast.AstAbstract;
import compiler.syntax.Ast.AstType;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstField;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstFieldAccess;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.Source.SourceSpan;
import compiler.syntax.SyntaxTree.SyntaxKind;
import compiler.syntax.SyntaxTree.SyntaxNode;
import compiler.syntax.SyntaxTree.SyntaxNodePayload;
import compiler.syntax.SyntaxTree.SyntaxExpressionPayload;
import compiler.syntax.SyntaxTree.SyntaxStatementPayload;
import compiler.syntax.SyntaxTree.SyntaxTypePayload;
import compiler.syntax.SyntaxTree.SyntaxTree;

typedef LoweredFunctionHeader = {
	final name:String;
	final isStatic:Bool;
	final isExtern:Bool;
	final typeParameters:Array<String>;
	final typeConstraints:Array<compiler.syntax.Ast.AstTypeConstraint>;
	final arguments:Array<AstArgument>;
	final result:AstType;
}

typedef LoweredClassHeader = {
	final name:String;
	final isPrivate:Bool;
	final isExtern:Bool;
	final typeParameters:Array<String>;
	final typeConstraints:Array<compiler.syntax.Ast.AstTypeConstraint>;
	final base:Null<AstType>;
	final interfaces:Array<AstType>;
}

typedef LoweredFieldHeader = {
	final name:String;
	final type:Null<AstType>;
	final initializer:Null<AstExpression>;
	final readAccess:Null<AstFieldAccess>;
	final writeAccess:Null<AstFieldAccess>;
	final isStatic:Bool;
	final isInline:Bool;
	final isFinal:Bool;
}

typedef LoweredTypeAliasHeader = {
	final name:String;
	final isPrivate:Bool;
	final typeParameters:Array<String>;
	final typeConstraints:Array<compiler.syntax.Ast.AstTypeConstraint>;
	final type:AstType;
}

typedef LoweredInterfaceHeader = {
	final name:String;
	final typeParameters:Array<String>;
	final typeConstraints:Array<compiler.syntax.Ast.AstTypeConstraint>;
	final bases:Array<AstType>;
}

/**
	Transition boundary from parser syntax to the compiler AST.

	The parser still owns AST construction while the CST grammar coverage is
	being completed. This boundary deliberately does not reparse source or keep
	AST references in syntax nodes. It validates the syntax outline against the
	direct AST and independently lowers the source header for the current
	transition.
	Once all AST-producing parser actions have syntax payloads, this is the only
	class that needs to change to construct AstProgram from CST nodes directly.
*/
class AstLowerer {
	static var requireComplete = false;

	public static function lower(tree:SyntaxTree, direct:AstProgram, strict:Bool = false):AstProgram {
		var previous = requireComplete;
		requireComplete = strict;
		var result:AstProgram;
		try {
			validateSpans(tree);
			validateDeclarations(tree, direct);
			result = lowerHeader(tree, direct);
		} catch (error:Dynamic) {
			requireComplete = previous;
			throw error;
		}
		requireComplete = previous;
		return result;
	}

	/**
		Lower the source header from CST payloads. Declaration and body fields stay
		on the direct AST until their syntax payloads are complete, so this first
		step exercises an independent lowering path without reparsing.
	*/
	static function lowerHeader(tree:SyntaxTree, direct:AstProgram):AstProgram {
		var packageName:Null<String> = null,
			imports:Array<String> = [],
			importAliases:Map<String, String> = [];
		for (node in tree.grammarNodes())
			switch node.payload {
				case SyntaxNodePayload.PackageName(value):
					packageName = value;
				case SyntaxNodePayload.Import(path, alias):
					imports.push(path);
					if (alias != null)
						importAliases.set(alias, path);
			case SyntaxNodePayload.ClassHeader(_, _, _, _, _, _), SyntaxNodePayload.ClassHeaderRich(_, _, _, _, _, _, _):
				case SyntaxNodePayload.FieldHeader(_, _, _, _, _, _, _), SyntaxNodePayload.FieldHeaderRich(_, _, _, _, _, _, _, _):
			case SyntaxNodePayload.FunctionHeader(_, _, _, _, _, _), SyntaxNodePayload.FunctionHeaderRich(_, _, _, _, _, _, _):
				case SyntaxNodePayload.Statement(_):
			case SyntaxNodePayload.TypeAliasHeader(_, _, _, _, _), SyntaxNodePayload.EnumHeader(_, _, _, _), SyntaxNodePayload.EnumAbstractHeader(_, _, _, _, _),
				SyntaxNodePayload.AbstractHeader(_, _, _, _, _, _, _), SyntaxNodePayload.InterfaceHeader(_, _, _, _):
				case null:
			}
		if (packageName == null && direct.packageName != null)
			throw "CST/AST lowering lost the package declaration";
		if (imports.length != direct.imports.length)
			throw 'CST/AST lowering lost imports: expected ${direct.imports.length}, got ${imports.length}';
		for (index in 0...imports.length)
			if (imports[index] != direct.imports[index])
				throw 'CST/AST lowering changed import ${direct.imports[index]}';
		var directAliasCount = 0;
		for (alias in direct.importAliases.keys()) {
			directAliasCount++;
			if (!importAliases.exists(alias) || importAliases.get(alias) != direct.importAliases.get(alias))
				throw 'CST/AST lowering changed import alias $alias';
		}
		var loweredAliasCount = 0;
		for (_ in importAliases.keys())
			loweredAliasCount++;
		if (loweredAliasCount != directAliasCount)
			throw "CST/AST lowering changed import alias count";
		return {
			packageName: packageName,
			imports: imports,
			importAliases: importAliases,
			aliases: lowerAliases(tree, direct.aliases),
			enums: lowerEnums(tree, direct.enums),
			enumAbstracts: lowerEnumAbstracts(tree, direct.enumAbstracts),
			abstracts: lowerAbstracts(tree, direct.abstracts),
			interfaces: lowerInterfaces(tree, direct.interfaces),
			classes: lowerClasses(tree, direct.classes),
			functions: lowerFunctions(tree, direct.functions)
		};
	}

	static function lowerAliases(tree:SyntaxTree, direct:Array<AstTypeAlias>):Array<AstTypeAlias> {
		var payloads = collectPayloads(tree), result:Array<AstTypeAlias> = [];
		for (alias in direct) {
			var header = lowerTypeAliasHeader(alias, payloads.get(alias.span.start)),
				lowered:Null<AstTypeAlias> = header == null ? null : {
					name: header.name,
					typeParameters: header.typeParameters,
					typeConstraints: header.typeConstraints,
					type: header.type,
					isPrivate: header.isPrivate,
					span: alias.span
				};
			result.push(keepOrFallback(lowered, alias, 'type alias ${alias.name}'));
		}
		return result;
	}

	static function lowerTypeAliasHeader(alias:AstTypeAlias, payload:Null<SyntaxNodePayload>):Null<LoweredTypeAliasHeader> {
		return switch payload {
			case SyntaxNodePayload.TypeAliasHeader(name, isPrivate, typeParameters, constraintPayloads, typePayload):
				var loweredType = lowerType(alias.type, typePayload),
					loweredConstraints = lowerTypeConstraints(alias.typeConstraints, constraintPayloads);
				if (loweredType == null || alias.name != name || alias.isPrivate != isPrivate || alias.typeParameters.length != typeParameters.length
					|| loweredConstraints == null)
					null;
				else {
					for (index in 0...alias.typeParameters.length)
						if (alias.typeParameters[index] != typeParameters[index])
							return null;
					{
						name: name,
						isPrivate: isPrivate,
						typeParameters: typeParameters,
						typeConstraints: loweredConstraints,
						type: loweredType
					};
				}
			default: null;
		};
	}

	static function lowerEnums(tree:SyntaxTree, direct:Array<AstEnum>):Array<AstEnum> {
		var payloads = collectPayloads(tree), result:Array<AstEnum> = [];
		for (enumeration in direct) {
			var lowered:Null<AstEnum> = switch payloads.get(enumeration.span.start) {
				case SyntaxNodePayload.EnumHeader(name, typeParameters, constraintPayloads, casePayloads):
					var cases = lowerEnumCases(enumeration.cases, casePayloads), valid = cases != null && enumeration.name == name
						&& enumeration.typeParameters.length == typeParameters.length
						&& lowerTypeConstraints(enumeration.typeConstraints, constraintPayloads) != null;
					var loweredConstraints = lowerTypeConstraints(enumeration.typeConstraints, constraintPayloads);
					for (index in 0...enumeration.typeParameters.length)
						if (enumeration.typeParameters[index] != typeParameters[index])
							valid = false;
					valid ? {name: name, typeParameters: typeParameters, typeConstraints: loweredConstraints, cases: cases, span: enumeration.span} : null;
				default: null;
			};
			result.push(keepOrFallback(lowered, enumeration, 'enum ${enumeration.name}'));
		}
		return result;
	}

	static function lowerEnumCases(direct:Array<compiler.syntax.Ast.AstEnumCase>, payload:Array<compiler.syntax.SyntaxTree.SyntaxEnumCasePayload>):Null<Array<compiler.syntax.Ast.AstEnumCase>> {
		if (direct.length != payload.length)
			return null;
		var result:Array<compiler.syntax.Ast.AstEnumCase> = [];
		for (index in 0...direct.length) {
			var source = direct[index], target = payload[index];
			if (source.name != target.name || source.params.length != target.parameters.length)
				return null;
			var parameters:Array<compiler.syntax.Ast.AstEnumParameter> = [];
			for (parameterIndex in 0...source.params.length) {
				var sourceParameter = source.params[parameterIndex], targetParameter = target.parameters[parameterIndex], loweredType = lowerType(sourceParameter.type, targetParameter.type);
				if (loweredType == null || sourceParameter.name != targetParameter.name || sourceParameter.optional != targetParameter.optional)
					return null;
				parameters.push({name: targetParameter.name, type: loweredType, optional: targetParameter.optional, span: sourceParameter.span});
			}
			result.push({name: target.name, params: parameters, span: source.span});
		}
		return result;
	}

	static function lowerEnumAbstracts(tree:SyntaxTree, direct:Array<AstEnumAbstract>):Array<AstEnumAbstract> {
		var payloads = collectPayloads(tree), result:Array<AstEnumAbstract> = [];
		for (declaration in direct) {
			var lowered:Null<AstEnumAbstract> = switch payloads.get(declaration.span.start) {
				case SyntaxNodePayload.EnumAbstractHeader(name, underlyingPayload, fromPayloads, toPayloads, valuePayloads):
					var underlying = lowerType(declaration.underlying, underlyingPayload), fromTypes = lowerTypeList(declaration.fromTypes, fromPayloads), toTypes = lowerTypeList(declaration.toTypes, toPayloads), values = lowerEnumValues(declaration.values, valuePayloads);
					underlying == null || fromTypes == null || toTypes == null || values == null || declaration.name != name ? null
						: {name: name, underlying: underlying, fromTypes: fromTypes, toTypes: toTypes, values: values, span: declaration.span};
				default: null;
			};
			result.push(keepOrFallback(lowered, declaration, 'enum abstract ${declaration.name}'));
		}
		return result;
	}

	static function lowerEnumValues(direct:Array<compiler.syntax.Ast.AstEnumAbstractValue>, payload:Array<compiler.syntax.SyntaxTree.SyntaxEnumValuePayload>):Null<Array<compiler.syntax.Ast.AstEnumAbstractValue>> {
		if (direct.length != payload.length)
			return null;
		var result:Array<compiler.syntax.Ast.AstEnumAbstractValue> = [];
		for (index in 0...direct.length) {
			var source = direct[index], target = payload[index], value = lowerExpression(source.value, target.value);
			if (value == null || source.name != target.name)
				return null;
			result.push({name: target.name, value: value, span: source.span});
		}
		return result;
	}

	static function lowerAbstracts(tree:SyntaxTree, direct:Array<AstAbstract>):Array<AstAbstract> {
		var payloads = collectPayloads(tree), result:Array<AstAbstract> = [];
		for (declaration in direct) {
			var lowered:Null<AstAbstract> = switch payloads.get(declaration.span.start) {
				case SyntaxNodePayload.AbstractHeader(name, isExtern, typeParameters, constraintPayloads, underlyingPayload, fromPayloads, toPayloads):
					var underlying = lowerType(declaration.underlying, underlyingPayload), fromTypes = lowerTypeList(declaration.fromTypes, fromPayloads), toTypes = lowerTypeList(declaration.toTypes, toPayloads);
					var loweredConstraints = lowerTypeConstraints(declaration.typeConstraints, constraintPayloads);
					var methods = lowerFunctionsFromPayloads(declaration.methods, payloads), valid = underlying != null && fromTypes != null && toTypes != null
						&& declaration.name == name && (declaration.isExtern == true) == isExtern && declaration.typeParameters.length == typeParameters.length
						&& loweredConstraints != null;
					for (index in 0...declaration.typeParameters.length)
						if (declaration.typeParameters[index] != typeParameters[index])
							valid = false;
					valid ? {name: name, isExtern: isExtern, metadata: declaration.metadata, typeParameters: typeParameters, typeConstraints: loweredConstraints, underlying: underlying, fromTypes: fromTypes, toTypes: toTypes, methods: methods, span: declaration.span} : null;
				default: null;
			};
			result.push(keepOrFallback(lowered, declaration, 'abstract ${declaration.name}'));
		}
		return result;
	}

	static function lowerInterfaces(tree:SyntaxTree, direct:Array<AstInterface>):Array<AstInterface> {
		var nodePayloads = collectPayloads(tree), result:Array<AstInterface> = [];
		for (interfaceDeclaration in direct) {
			var header = lowerInterfaceHeader(interfaceDeclaration, nodePayloads.get(interfaceDeclaration.span.start)),
				lowered:Null<AstInterface> = header == null ? null : {
					name: header.name,
					typeParameters: header.typeParameters,
					typeConstraints: header.typeConstraints,
					bases: header.bases,
					methods: lowerFunctionsFromPayloads(interfaceDeclaration.methods, nodePayloads),
					span: interfaceDeclaration.span
				};
			result.push(keepOrFallback(lowered, interfaceDeclaration, 'interface ${interfaceDeclaration.name}'));
		}
		return result;
	}

	static function lowerInterfaceHeader(interfaceDeclaration:AstInterface, payload:Null<SyntaxNodePayload>):Null<LoweredInterfaceHeader> {
		return switch payload {
			case SyntaxNodePayload.InterfaceHeader(name, typeParameters, constraintPayloads, basePayloads):
				var loweredBases = lowerTypeList(interfaceDeclaration.bases, basePayloads),
					loweredConstraints = lowerTypeConstraints(interfaceDeclaration.typeConstraints, constraintPayloads);
				if (loweredBases == null || loweredConstraints == null || name != interfaceDeclaration.name
					|| typeParameters.length != interfaceDeclaration.typeParameters.length)
					null;
				else {
					for (index in 0...interfaceDeclaration.typeParameters.length)
						if (interfaceDeclaration.typeParameters[index] != typeParameters[index])
							return null;
					{
						name: name,
						typeParameters: typeParameters,
						typeConstraints: loweredConstraints,
						bases: loweredBases
					};
				}
			default: null;
		};
	}

	static function lowerFunctions(tree:SyntaxTree, direct:Array<AstFunction>):Array<AstFunction>
		return lowerFunctionsFromPayloads(direct, collectPayloads(tree));

	static function lowerFunctionsFromPayloads(direct:Array<AstFunction>, nodePayloads:Map<Int, SyntaxNodePayload>):Array<AstFunction> {
		var result:Array<AstFunction> = [];
		for (functionDeclaration in direct) {
			var lowered = lowerFunction(functionDeclaration, nodePayloads.get(functionDeclaration.span.start), nodePayloads);
			result.push(keepOrFallback(lowered, functionDeclaration, 'function ${functionDeclaration.name}'));
		}
		return result;
	}

	static function lowerClasses(tree:SyntaxTree, direct:Array<AstClass>):Array<AstClass> {
		var nodePayloads = collectPayloads(tree);
		var result:Array<AstClass> = [];
		for (classDeclaration in direct) {
			var header = lowerClassHeader(classDeclaration, nodePayloads.get(classDeclaration.span.start));
			var fields = lowerFields(classDeclaration.fields, nodePayloads),
				methods = lowerFunctionsFromPayloads(classDeclaration.methods, nodePayloads),
				name = header == null ? classDeclaration.name : header.name,
				isExtern = header == null ? classDeclaration.isExtern : header.isExtern,
				typeParameters = header == null ? classDeclaration.typeParameters : header.typeParameters,
				typeConstraints = header == null ? classDeclaration.typeConstraints : header.typeConstraints,
				isPrivate = header == null ? classDeclaration.isPrivate : header.isPrivate,
				base = header == null ? classDeclaration.base : header.base,
				interfaces = header == null ? classDeclaration.interfaces : header.interfaces;
			result.push({
				name: name,
				isExtern: isExtern,
				typeParameters: typeParameters,
				typeConstraints: typeConstraints,
				isPrivate: isPrivate,
				metadata: classDeclaration.metadata,
				base: base,
				interfaces: interfaces,
				fields: fields,
				methods: methods,
				span: classDeclaration.span
			});
		}
		return result;
	}

	static function lowerClassHeader(classDeclaration:AstClass, payload:Null<SyntaxNodePayload>):Null<LoweredClassHeader> {
		return switch payload {
			case SyntaxNodePayload.ClassHeader(name, isPrivate, isExtern, typeParameters, baseName, interfaceNames):
				if (classDeclaration.typeParameters.length != typeParameters.length
					|| classDeclaration.typeConstraints != null && classDeclaration.typeConstraints.length > 0
					|| !simpleTypeMatches(classDeclaration.base, baseName)
					|| classDeclaration.interfaces.length != interfaceNames.length)
					null;
				else {
					for (index in 0...classDeclaration.typeParameters.length)
						if (classDeclaration.typeParameters[index] != typeParameters[index])
							return null;
					for (index in 0...classDeclaration.interfaces.length) {
						var interfaceName = interfaceNames[index];
						if (interfaceName == null || !simpleTypeMatches(classDeclaration.interfaces[index], interfaceName))
							return null;
					}
					{
						name: name,
						isPrivate: isPrivate,
						isExtern: isExtern,
						typeParameters: typeParameters,
						typeConstraints: [],
						base: baseName == null ? null : NamedType(baseName),
						interfaces: [for (interfaceName in interfaceNames) NamedType(interfaceName)]
					};
				}
			case SyntaxNodePayload.ClassHeaderRich(name, isPrivate, isExtern, typeParameters, constraintPayloads, baseType, interfaceTypes):
				if (classDeclaration.name != name || classDeclaration.isPrivate != isPrivate || (classDeclaration.isExtern == true) != isExtern
					|| classDeclaration.typeParameters.length != typeParameters.length
					|| classDeclaration.interfaces.length != interfaceTypes.length
					|| classDeclaration.base != null != (baseType != null))
					null;
				else {
					for (index in 0...classDeclaration.typeParameters.length)
						if (classDeclaration.typeParameters[index] != typeParameters[index])
							return null;
					var loweredConstraints = lowerTypeConstraints(classDeclaration.typeConstraints, constraintPayloads),
						loweredBase = baseType == null ? null : lowerType(classDeclaration.base, baseType),
						loweredInterfaces = lowerTypeList(classDeclaration.interfaces, interfaceTypes);
					if (loweredConstraints == null || baseType != null && loweredBase == null || loweredInterfaces == null)
						null;
					else
						{
							name: name,
							isPrivate: isPrivate,
							isExtern: isExtern,
							typeParameters: typeParameters,
							typeConstraints: loweredConstraints,
							base: loweredBase,
							interfaces: loweredInterfaces
						};
				}
			default: null;
		};
	}

	static function collectPayloads(tree:SyntaxTree):Map<Int, SyntaxNodePayload> {
		return tree.payloadsByStart();
	}

	static function lowerFields(direct:Array<AstField>, nodePayloads:Map<Int, SyntaxNodePayload>):Array<AstField> {
		var result:Array<AstField> = [];
		for (field in direct) {
			var header = lowerFieldHeader(field, nodePayloads.get(field.span.start)),
				lowered:Null<AstField> = header == null ? null : {
					name: header.name,
					metadata: field.metadata,
					type: header.type,
					initializer: header.initializer,
					readAccess: header.readAccess,
					writeAccess: header.writeAccess,
					isStatic: header.isStatic,
					isInline: header.isInline,
					isFinal: header.isFinal,
					span: field.span
				};
			result.push(keepOrFallback(lowered, field, 'field ${field.name}'));
		}
		return result;
	}


	static function lowerFieldHeader(field:AstField, payload:Null<SyntaxNodePayload>):Null<LoweredFieldHeader> {
		return switch payload {
			case SyntaxNodePayload.FieldHeader(name, typeName, isStatic, isInline, isFinal, readAccess, writeAccess):
				if (field.initializer != null || typeName == null || !simpleTypeMatches(field.type, typeName)
					|| field.isStatic != isStatic || field.isInline != isInline || field.isFinal != isFinal
					|| fieldAccessName(field.readAccess) != readAccess || fieldAccessName(field.writeAccess) != writeAccess)
					null;
				else
					{
						name: name,
						type: lowerSimpleType(typeName),
						initializer: null,
						readAccess: lowerFieldAccess(readAccess),
						writeAccess: lowerFieldAccess(writeAccess),
						isStatic: isStatic,
						isInline: isInline,
						isFinal: isFinal
					};
			case SyntaxNodePayload.FieldHeaderRich(name, typePayload, initializerPayload, isStatic, isInline, isFinal, readAccess, writeAccess):
				var loweredType = field.type == null ? null : typePayload == null ? null : lowerType(field.type, typePayload),
					loweredInitializer = field.initializer == null ? null : initializerPayload == null ? null : lowerExpression(field.initializer, initializerPayload);
				if (field.type != null && loweredType == null || field.initializer != null && loweredInitializer == null
					|| field.type == null && typePayload != null || field.initializer == null && initializerPayload != null
					|| field.name != name || field.isStatic != isStatic || field.isInline != isInline || field.isFinal != isFinal
					|| fieldAccessName(field.readAccess) != readAccess || fieldAccessName(field.writeAccess) != writeAccess)
					null;
				else
					{
						name: name,
						type: loweredType,
						initializer: loweredInitializer,
						readAccess: lowerFieldAccess(readAccess),
						writeAccess: lowerFieldAccess(writeAccess),
						isStatic: isStatic,
						isInline: isInline,
						isFinal: isFinal
					};
			default: null;
		};
	}

	static function lowerFunction(functionDeclaration:AstFunction, payload:Null<SyntaxNodePayload>,
			nodePayloads:Map<Int, SyntaxNodePayload>):Null<AstFunction> {
		var header = lowerFunctionHeader(functionDeclaration, payload);
		if (header == null)
			return null;
		var statements = lowerStatements(functionDeclaration.statements, nodePayloads);
		return statements == null ? null : {
			name: header.name,
			isStatic: header.isStatic,
			isExtern: header.isExtern,
			metadata: [],
			typeParameters: header.typeParameters,
			typeConstraints: header.typeConstraints,
			arguments: header.arguments,
			result: header.result,
			statements: statements,
			span: functionDeclaration.span
		};
	}

	static function lowerFunctionHeader(functionDeclaration:AstFunction, payload:Null<SyntaxNodePayload>):Null<LoweredFunctionHeader> {
		return switch payload {
			case SyntaxNodePayload.FunctionHeaderRich(name, isStatic, isExtern, typeParameters, constraintPayloads, parameters, resultType):
				var directTypeParameters = functionDeclaration.typeParameters == null ? [] : functionDeclaration.typeParameters,
					loweredResult = lowerType(functionDeclaration.result, resultType),
					loweredArguments = lowerArguments(functionDeclaration.arguments, parameters),
					loweredConstraints = lowerTypeConstraints(functionDeclaration.typeConstraints, constraintPayloads);
				if (loweredResult == null || loweredArguments == null || functionDeclaration.metadata != null && functionDeclaration.metadata.length > 0
					|| loweredConstraints == null || functionDeclaration.name != name
					|| functionDeclaration.isStatic != isStatic || (functionDeclaration.isExtern == true) != isExtern
					|| directTypeParameters.length != typeParameters.length)
					null;
				else {
					for (index in 0...directTypeParameters.length)
						if (directTypeParameters[index] != typeParameters[index])
							return null;
					{
						name: name,
						isStatic: isStatic,
						isExtern: isExtern,
						typeParameters: typeParameters,
						typeConstraints: loweredConstraints,
						arguments: loweredArguments,
						result: loweredResult
					};
				}
			case SyntaxNodePayload.FunctionHeader(name, isStatic, isExtern, typeParameters, parameters, resultTypeName):
				var directTypeParameters = functionDeclaration.typeParameters == null ? [] : functionDeclaration.typeParameters;
				if (functionDeclaration.metadata != null && functionDeclaration.metadata.length > 0
					|| functionDeclaration.typeConstraints != null && functionDeclaration.typeConstraints.length > 0
					|| resultTypeName == null || !simpleTypeMatches(functionDeclaration.result, resultTypeName)
					|| functionDeclaration.arguments.length != parameters.length
					|| functionDeclaration.name != name || functionDeclaration.isStatic != isStatic
					|| (functionDeclaration.isExtern == true) != isExtern
					|| directTypeParameters.length != typeParameters.length)
					null;
				else {
					var loweredArguments:Array<AstArgument> = [];
					for (index in 0...directTypeParameters.length)
						if (directTypeParameters[index] != typeParameters[index])
							return null;
					for (index in 0...parameters.length) {
						var sourceArgument = functionDeclaration.arguments[index], parameter = parameters[index];
						if (sourceArgument.defaultValue != null || parameter.typeName == null
							|| sourceArgument.name != parameter.name || sourceArgument.optional != parameter.optional
							|| !simpleTypeMatches(sourceArgument.type, parameter.typeName))
							return null;
						loweredArguments.push({
							name: parameter.name,
							type: lowerSimpleType(parameter.typeName),
							span: sourceArgument.span,
							optional: parameter.optional,
							defaultValue: null
						});
					}
					{
						name: name,
						isStatic: isStatic,
						isExtern: isExtern,
						typeParameters: typeParameters,
						typeConstraints: [],
						arguments: loweredArguments,
						result: lowerSimpleType(resultTypeName)
					};
				}
			default: null;
		};
	}

	static function lowerStatements(direct:Array<AstStatement>, nodePayloads:Map<Int, SyntaxNodePayload>):Null<Array<AstStatement>> {
		var result:Array<AstStatement> = [];
		for (statement in direct) {
			var lowered:Null<AstStatement> = switch nodePayloads.get(statementSpan(statement).start) {
				case SyntaxNodePayload.Statement(value): lowerStatement(statement, value);
				default: null;
			};
			if (lowered == null)
				return null;
			result.push(lowered);
		}
		return result;
	}

	static function lowerStatement(statement:AstStatement, payload:SyntaxStatementPayload):Null<AstStatement>
		return switch [statement, payload] {
			case [ErrorStatement(span), SyntaxStatementPayload.Error]: ErrorStatement(span);
			case [UninitializedDeclaration(name, type, span), SyntaxStatementPayload.UninitializedDeclaration(payloadName, payloadType)]:
				var loweredType = lowerType(type, payloadType);
				loweredType == null || name != payloadName ? null : UninitializedDeclaration(payloadName, loweredType, span);
			case [VarDeclaration(name, type, initializer, span), SyntaxStatementPayload.VarDeclaration(payloadName, payloadType, initializerPayload)]:
				var loweredInitializer = lowerExpression(initializer, initializerPayload), loweredType = type == null ? null : lowerType(type, payloadType);
				loweredInitializer == null || type != null && loweredType == null || name != payloadName ? null
					: VarDeclaration(payloadName, loweredType, loweredInitializer, span);
			case [Assignment(name, expression, span), SyntaxStatementPayload.Assignment(payloadName, expressionPayload)]:
				var loweredExpression = lowerExpression(expression, expressionPayload);
				loweredExpression == null || name != payloadName ? null : Assignment(payloadName, loweredExpression, span);
			case [IndexAssignment(array, index, expression, span), SyntaxStatementPayload.IndexAssignment(arrayPayload, indexPayload, expressionPayload)]:
				var loweredArray = lowerExpression(array, arrayPayload), loweredIndex = lowerExpression(index, indexPayload), loweredExpression = lowerExpression(expression, expressionPayload);
				loweredArray == null || loweredIndex == null || loweredExpression == null ? null : IndexAssignment(loweredArray, loweredIndex, loweredExpression, span);
			case [FieldAssignment(object, field, expression, span), SyntaxStatementPayload.FieldAssignment(objectPayload, payloadField, expressionPayload)]:
				var loweredObject = lowerExpression(object, objectPayload), loweredExpression = lowerExpression(expression, expressionPayload);
				loweredObject == null || loweredExpression == null || field != payloadField ? null : FieldAssignment(loweredObject, payloadField, loweredExpression, span);
			case [Break(span), SyntaxStatementPayload.Break]: Break(span);
			case [Continue(span), SyntaxStatementPayload.Continue]: Continue(span);
			case [ReturnVoid(span), SyntaxStatementPayload.ReturnVoid]: ReturnVoid(span);
			case [Return(expression, span), SyntaxStatementPayload.Return(value)]:
				var loweredExpression = lowerExpression(expression, value);
				loweredExpression == null ? null : Return(loweredExpression, span);
			case [AstStatement.If(condition, thenBranch, elseBranch, span), SyntaxStatementPayload.IfBranch(conditionPayload, thenPayload, elsePayload)]:
				var loweredCondition = lowerExpression(condition, conditionPayload),
					loweredThen = lowerStatementList(thenBranch, thenPayload),
					loweredElse = lowerStatementList(elseBranch, elsePayload);
			loweredCondition == null || loweredThen == null || loweredElse == null ? null
					: AstStatement.If(loweredCondition, loweredThen, loweredElse, span);
			case [AstStatement.While(condition, body, span), SyntaxStatementPayload.WhileLoop(conditionPayload, bodyPayload)]:
				var loweredCondition = lowerExpression(condition, conditionPayload), loweredBody = lowerStatementList(body, bodyPayload);
				loweredCondition == null || loweredBody == null ? null : AstStatement.While(loweredCondition, loweredBody, span);
			case [AstStatement.DoWhile(body, condition, span), SyntaxStatementPayload.DoWhileLoop(bodyPayload, conditionPayload)]:
				var loweredBody = lowerStatementList(body, bodyPayload), loweredCondition = lowerExpression(condition, conditionPayload);
				loweredBody == null || loweredCondition == null ? null : AstStatement.DoWhile(loweredBody, loweredCondition, span);
			case [AstStatement.ForIn(keyName, valueName, iterable, body, span), SyntaxStatementPayload.ForLoop(payloadKeyName, payloadValueName, iterablePayload, bodyPayload)]:
				var loweredIterable = lowerExpression(iterable, iterablePayload), loweredBody = lowerStatementList(body, bodyPayload);
				loweredIterable == null || keyName != payloadKeyName || valueName != payloadValueName || loweredBody == null ? null
					: AstStatement.ForIn(payloadKeyName, payloadValueName, loweredIterable, loweredBody, span);
			case [Throw(expression, span), SyntaxStatementPayload.Throw(expressionPayload)]:
				var loweredExpression = lowerExpression(expression, expressionPayload);
				loweredExpression == null ? null : Throw(loweredExpression, span);
			case [Try(tryBranch, catches, span), SyntaxStatementPayload.Try(tryPayload, catchPayloads)]:
				var loweredTry = lowerStatementList(tryBranch, tryPayload), loweredCatches = lowerCatches(catches, catchPayloads);
				loweredTry == null || loweredCatches == null ? null : Try(loweredTry, loweredCatches, span);
			case [Switch(expression, cases, defaultBranch, hasDefault, span), SyntaxStatementPayload.Switch(expressionPayload, casePayloads, defaultPayload, payloadHasDefault)]:
				var loweredExpression = lowerExpression(expression, expressionPayload), loweredCases = lowerSwitchCases(cases, casePayloads), loweredDefault = lowerStatementList(defaultBranch, defaultPayload);
				loweredExpression == null || loweredCases == null || loweredDefault == null || hasDefault != payloadHasDefault ? null
					: Switch(loweredExpression, loweredCases, loweredDefault, payloadHasDefault, span);
			case [Increment(name, delta, span), SyntaxStatementPayload.Increment(payloadName, payloadDelta)]:
				name != payloadName || delta != payloadDelta ? null : Increment(payloadName, payloadDelta, span);
			case [Expression(expression, span), SyntaxStatementPayload.Expression(expressionPayload)]:
				var loweredExpression = lowerExpression(expression, expressionPayload);
				loweredExpression == null ? null : Expression(loweredExpression, span);
			default: null;
		};

	static function lowerCatches(direct:Array<compiler.syntax.Ast.AstCatch>, payload:Array<compiler.syntax.SyntaxTree.SyntaxCatchPayload>):Null<Array<compiler.syntax.Ast.AstCatch>> {
		if (direct.length != payload.length)
			return null;
		var result:Array<compiler.syntax.Ast.AstCatch> = [];
		for (index in 0...direct.length) {
			var catchClause = direct[index], payloadCatch = payload[index], loweredType = lowerType(catchClause.type, payloadCatch.type), loweredStatements = lowerStatementList(catchClause.statements, payloadCatch.statements);
			if (loweredType == null || loweredStatements == null || catchClause.name != payloadCatch.name)
				return null;
			result.push({name: payloadCatch.name, type: loweredType, statements: loweredStatements, span: catchClause.span});
		}
		return result;
	}

	static function lowerSwitchCases(direct:Array<compiler.syntax.Ast.AstSwitchCase>, payload:Array<compiler.syntax.SyntaxTree.SyntaxSwitchCasePayload>):Null<Array<compiler.syntax.Ast.AstSwitchCase>> {
		if (direct.length != payload.length)
			return null;
		var result:Array<compiler.syntax.Ast.AstSwitchCase> = [];
		for (index in 0...direct.length) {
			var caseClause = direct[index], payloadCase = payload[index], loweredValue = lowerExpression(caseClause.value, payloadCase.value), loweredGuard = caseClause.guard == null ? null : lowerExpression(caseClause.guard, payloadCase.guard), loweredStatements = lowerStatementList(caseClause.statements, payloadCase.statements);
			if (loweredValue == null || caseClause.guard != null && loweredGuard == null || loweredStatements == null)
				return null;
			result.push({value: loweredValue, guard: loweredGuard, statements: loweredStatements, span: caseClause.span});
		}
		return result;
	}

	static function lowerStatementList(direct:Array<AstStatement>, payloads:Array<SyntaxStatementPayload>):Null<Array<AstStatement>> {
		if (direct.length != payloads.length)
			return null;
		var result:Array<AstStatement> = [];
		for (index in 0...direct.length) {
			var lowered = lowerStatement(direct[index], payloads[index]);
			if (lowered == null)
				return null;
			result.push(lowered);
		}
		return result;
	}

	static function lowerType(direct:AstType, payload:compiler.syntax.SyntaxTree.SyntaxTypePayload):Null<AstType>
		return switch payload {
			case compiler.syntax.SyntaxTree.SyntaxTypePayload.IntType: IntType;
			case compiler.syntax.SyntaxTree.SyntaxTypePayload.BoolType: BoolType;
			case compiler.syntax.SyntaxTree.SyntaxTypePayload.FloatType: FloatType;
			case compiler.syntax.SyntaxTree.SyntaxTypePayload.StringType: StringType;
			case compiler.syntax.SyntaxTree.SyntaxTypePayload.VoidType: VoidType;
			case compiler.syntax.SyntaxTree.SyntaxTypePayload.InferredType: InferredType;
			case SyntaxTypePayload.ErrorType:
				switch direct {
					case ErrorType(span): ErrorType(span);
					default: null;
				};
			case SyntaxTypePayload.NativeAbstractType(declaration, tag): NativeAbstractType(declaration, tag);
			case compiler.syntax.SyntaxTree.SyntaxTypePayload.NamedType(name): NamedType(name);
			case compiler.syntax.SyntaxTree.SyntaxTypePayload.AppliedType(name, payloadArguments):
				var lowered:Array<AstType> = [];
				for (argument in payloadArguments) {
					var loweredArgument = lowerType(null, argument);
					if (loweredArgument == null)
						return null;
					lowered.push(loweredArgument);
				}
				AppliedType(name, lowered);
			case compiler.syntax.SyntaxTree.SyntaxTypePayload.ArrayType(payloadElement):
				var lowered = lowerType(null, payloadElement);
				lowered == null ? null : ArrayType(lowered);
			case compiler.syntax.SyntaxTree.SyntaxTypePayload.MapType(payloadKey, payloadValue):
				var loweredKey = lowerType(null, payloadKey), loweredValue = lowerType(null, payloadValue);
				loweredKey == null || loweredValue == null ? null : MapType(loweredKey, loweredValue);
			case compiler.syntax.SyntaxTree.SyntaxTypePayload.NullableType(payloadElement):
				var lowered = lowerType(null, payloadElement);
				lowered == null ? null : NullableType(lowered);
			case compiler.syntax.SyntaxTree.SyntaxTypePayload.FunctionType(payloadArguments, payloadResult):
				var loweredArguments:Array<AstType> = [];
				for (argument in payloadArguments) {
					var loweredArgument = lowerType(null, argument);
					if (loweredArgument == null)
						return null;
					loweredArguments.push(loweredArgument);
				}
				var loweredResult = lowerType(null, payloadResult);
				loweredResult == null ? null : FunctionType(loweredArguments, loweredResult);
			case compiler.syntax.SyntaxTree.SyntaxTypePayload.AnonymousType(payloadFields):
				var loweredFields:Array<compiler.syntax.Ast.AstAnonymousField> = [];
				for (payloadField in payloadFields) {
					var lowered = lowerType(null, payloadField.type);
					if (lowered == null)
						return null;
					loweredFields.push({name: payloadField.name, type: lowered, optional: payloadField.optional, span: payloadField.span});
				}
				AnonymousType(loweredFields);
		};

	static function lowerTypeList(direct:Array<AstType>, payload:Array<compiler.syntax.SyntaxTree.SyntaxTypePayload>):Null<Array<AstType>> {
		if (direct.length != payload.length)
			return null;
		var result:Array<AstType> = [];
		for (index in 0...direct.length) {
			var lowered = lowerType(direct[index], payload[index]);
			if (lowered == null)
				return null;
			result.push(lowered);
		}
		return result;
	}

	static function lowerTypeConstraints(direct:Null<Array<compiler.syntax.Ast.AstTypeConstraint>>,
			payload:Array<compiler.syntax.SyntaxTree.SyntaxTypeConstraintPayload>):Null<Array<compiler.syntax.Ast.AstTypeConstraint>> {
		var source = direct == null ? [] : direct;
		if (source.length != payload.length)
			return null;
		var result:Array<compiler.syntax.Ast.AstTypeConstraint> = [];
		for (index in 0...source.length) {
			var sourceConstraint = source[index], payloadConstraint = payload[index], lowered = lowerType(sourceConstraint.type, payloadConstraint.type);
			if (lowered == null || sourceConstraint.parameter != payloadConstraint.parameter)
				return null;
			result.push({parameter: payloadConstraint.parameter, type: lowered, span: sourceConstraint.span});
		}
		return result;
	}

	static function lowerExpression(expression:AstExpression, payload:SyntaxExpressionPayload):Null<AstExpression>
		return switch [expression, payload] {
			case [IntegerLiteral(_, span), SyntaxExpressionPayload.Integer(value)]: IntegerLiteral(value, span);
			case [FloatLiteral(_, span), SyntaxExpressionPayload.Float(value)]: FloatLiteral(value, span);
			case [StringLiteral(_, span), SyntaxExpressionPayload.String(value)]: StringLiteral(value, span);
			case [BoolLiteral(_, span), SyntaxExpressionPayload.Bool(value)]: BoolLiteral(value, span);
			case [NullLiteral(span), SyntaxExpressionPayload.NullValue]: NullLiteral(span);
			case [Unreachable(span), SyntaxExpressionPayload.Unreachable]: Unreachable(span);
			case [EmptyExpression(span), SyntaxExpressionPayload.Empty]: EmptyExpression(span);
			case [ErrorExpression(span), SyntaxExpressionPayload.Error]: ErrorExpression(span);
			case [Variable(_, span), SyntaxExpressionPayload.Variable(name)]: Variable(name, span);
			case [Member(object, _, span), SyntaxExpressionPayload.Member(objectPayload, name)]:
				var loweredObject = lowerExpression(object, objectPayload);
				loweredObject == null ? null : Member(loweredObject, name, span);
			case [Add(left, right, span), SyntaxExpressionPayload.Binary(operation, leftPayload, rightPayload)]:
				lowerBinary(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Add, left, right, span, operation, leftPayload, rightPayload);
			case [Sub(left, right, span), SyntaxExpressionPayload.Binary(operation, leftPayload, rightPayload)]:
				lowerBinary(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Sub, left, right, span, operation, leftPayload, rightPayload);
			case [Mul(left, right, span), SyntaxExpressionPayload.Binary(operation, leftPayload, rightPayload)]:
				lowerBinary(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Mul, left, right, span, operation, leftPayload, rightPayload);
			case [Div(left, right, span), SyntaxExpressionPayload.Binary(operation, leftPayload, rightPayload)]:
				lowerBinary(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Div, left, right, span, operation, leftPayload, rightPayload);
			case [Mod(left, right, span), SyntaxExpressionPayload.Binary(operation, leftPayload, rightPayload)]:
				lowerBinary(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Mod, left, right, span, operation, leftPayload, rightPayload);
			case [BitAnd(left, right, span), SyntaxExpressionPayload.Binary(operation, leftPayload, rightPayload)]:
				lowerBinary(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.BitAnd, left, right, span, operation, leftPayload, rightPayload);
			case [BitXor(left, right, span), SyntaxExpressionPayload.Binary(operation, leftPayload, rightPayload)]:
				lowerBinary(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.BitXor, left, right, span, operation, leftPayload, rightPayload);
			case [BitOr(left, right, span), SyntaxExpressionPayload.Binary(operation, leftPayload, rightPayload)]:
				lowerBinary(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.BitOr, left, right, span, operation, leftPayload, rightPayload);
			case [ShiftLeft(left, right, span), SyntaxExpressionPayload.Binary(operation, leftPayload, rightPayload)]:
				lowerBinary(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.ShiftLeft, left, right, span, operation, leftPayload, rightPayload);
			case [ShiftRight(left, right, span), SyntaxExpressionPayload.Binary(operation, leftPayload, rightPayload)]:
				lowerBinary(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.ShiftRight, left, right, span, operation, leftPayload, rightPayload);
			case [UnsignedShiftRight(left, right, span), SyntaxExpressionPayload.Binary(operation, leftPayload, rightPayload)]:
				lowerBinary(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.UnsignedShiftRight, left, right, span, operation, leftPayload, rightPayload);
			case [Less(left, right, span), SyntaxExpressionPayload.Binary(operation, leftPayload, rightPayload)]:
				lowerBinary(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Less, left, right, span, operation, leftPayload, rightPayload);
			case [LessEqual(left, right, span), SyntaxExpressionPayload.Binary(operation, leftPayload, rightPayload)]:
				lowerBinary(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.LessEqual, left, right, span, operation, leftPayload, rightPayload);
			case [Greater(left, right, span), SyntaxExpressionPayload.Binary(operation, leftPayload, rightPayload)]:
				lowerBinary(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Greater, left, right, span, operation, leftPayload, rightPayload);
			case [GreaterEqual(left, right, span), SyntaxExpressionPayload.Binary(operation, leftPayload, rightPayload)]:
				lowerBinary(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.GreaterEqual, left, right, span, operation, leftPayload, rightPayload);
			case [Equal(left, right, span), SyntaxExpressionPayload.Binary(operation, leftPayload, rightPayload)]:
				lowerBinary(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Equal, left, right, span, operation, leftPayload, rightPayload);
			case [NotEqual(left, right, span), SyntaxExpressionPayload.Binary(operation, leftPayload, rightPayload)]:
				lowerBinary(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.NotEqual, left, right, span, operation, leftPayload, rightPayload);
			case [And(left, right, span), SyntaxExpressionPayload.Binary(operation, leftPayload, rightPayload)]:
				lowerBinary(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.And, left, right, span, operation, leftPayload, rightPayload);
			case [Or(left, right, span), SyntaxExpressionPayload.Binary(operation, leftPayload, rightPayload)]:
				lowerBinary(compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Or, left, right, span, operation, leftPayload, rightPayload);
			case [Negate(value, span), SyntaxExpressionPayload.Unary(operation, valuePayload)]:
				lowerUnary(compiler.syntax.SyntaxTree.SyntaxUnaryOperator.Negate, value, span, operation, valuePayload);
			case [Not(value, span), SyntaxExpressionPayload.Unary(operation, valuePayload)]:
				lowerUnary(compiler.syntax.SyntaxTree.SyntaxUnaryOperator.Not, value, span, operation, valuePayload);
			case [Conditional(condition, whenTrue, whenFalse, span), SyntaxExpressionPayload.Conditional(conditionPayload, truePayload, falsePayload)]:
				var loweredCondition = lowerExpression(condition, conditionPayload), loweredTrue = lowerExpression(whenTrue, truePayload), loweredFalse = lowerExpression(whenFalse, falsePayload);
				loweredCondition == null || loweredTrue == null || loweredFalse == null ? null : Conditional(loweredCondition, loweredTrue, loweredFalse, span);
			case [BlockExpression(statements, result, span), SyntaxExpressionPayload.Block(statementPayloads, resultPayload)]:
				var loweredStatements = lowerStatementList(statements, statementPayloads), loweredResult = lowerExpression(result, resultPayload);
				loweredStatements == null || loweredResult == null ? null : BlockExpression(loweredStatements, loweredResult, span);
			case [ThrowExpression(value, span), SyntaxExpressionPayload.Throw(valuePayload)]:
				var loweredValue = lowerExpression(value, valuePayload);
				loweredValue == null ? null : ThrowExpression(loweredValue, span);
			case [Cast(value, target, span), SyntaxExpressionPayload.Cast(valuePayload, targetPayload)]:
				var loweredValue = lowerExpression(value, valuePayload), loweredTarget = target == null ? null : lowerType(target, targetPayload);
				loweredValue == null || target != null && loweredTarget == null ? null : Cast(loweredValue, loweredTarget, span);
			case [SwitchExpression(value, cases, defaultExpression, span), SyntaxExpressionPayload.Switch(valuePayload, casePayloads, defaultPayload)]:
				var loweredValue = lowerExpression(value, valuePayload), loweredCases = lowerSwitchExpressionCases(cases, casePayloads), loweredDefault = defaultExpression == null ? null : lowerExpression(defaultExpression, defaultPayload);
				loweredValue == null || loweredCases == null || defaultExpression != null && loweredDefault == null ? null
					: SwitchExpression(loweredValue, loweredCases, loweredDefault, span);
			case [ObjectLiteral(fields, span), SyntaxExpressionPayload.Object(fieldPayloads)]:
				var loweredFields = lowerObjectFields(fields, fieldPayloads);
				loweredFields == null ? null : ObjectLiteral(loweredFields, span);
			case [ArrayLiteral(values, span), SyntaxExpressionPayload.Array(valuePayloads)]:
				var loweredValues = lowerExpressionList(values, valuePayloads);
				loweredValues == null ? null : ArrayLiteral(loweredValues, span);
			case [MapLiteral(entries, span), SyntaxExpressionPayload.Map(entryPayloads)]:
				var loweredEntries = lowerMapEntries(entries, entryPayloads);
				loweredEntries == null ? null : MapLiteral(loweredEntries, span);
			case [ArrayComprehension(keyName, valueName, iterable, condition, value, span), SyntaxExpressionPayload.ArrayComprehension(payloadKeyName, payloadValueName, iterablePayload, conditionPayload, valuePayload)]:
				var loweredIterable = lowerExpression(iterable, iterablePayload), loweredCondition = condition == null ? null : lowerExpression(condition, conditionPayload), loweredValue = lowerExpression(value, valuePayload);
				loweredIterable == null || condition != null && loweredCondition == null || loweredValue == null || keyName != payloadKeyName || valueName != payloadValueName ? null
					: ArrayComprehension(payloadKeyName, payloadValueName, loweredIterable, loweredCondition, loweredValue, span);
			case [MapComprehension(keyName, valueName, iterable, condition, key, value, span), SyntaxExpressionPayload.MapComprehension(payloadKeyName, payloadValueName, iterablePayload, conditionPayload, keyPayload, valuePayload)]:
				var loweredIterable = lowerExpression(iterable, iterablePayload), loweredCondition = condition == null ? null : lowerExpression(condition, conditionPayload), loweredKey = lowerExpression(key, keyPayload), loweredValue = lowerExpression(value, valuePayload);
				loweredIterable == null || condition != null && loweredCondition == null || loweredKey == null || loweredValue == null || keyName != payloadKeyName || valueName != payloadValueName ? null
					: MapComprehension(payloadKeyName, payloadValueName, loweredIterable, loweredCondition, loweredKey, loweredValue, span);
			case [Range(start, end, span), SyntaxExpressionPayload.Range(startPayload, endPayload)]:
				var loweredStart = lowerExpression(start, startPayload), loweredEnd = lowerExpression(end, endPayload);
				loweredStart == null || loweredEnd == null ? null : Range(loweredStart, loweredEnd, span);
			case [Call(name, arguments, span), SyntaxExpressionPayload.Call(payloadName, argumentPayloads)]:
				var loweredArguments = lowerExpressionList(arguments, argumentPayloads);
				loweredArguments == null || name != payloadName ? null : Call(payloadName, loweredArguments, span);
			case [NativeLayoutQuery(kind, type, field, span), SyntaxExpressionPayload.NativeLayoutQuery(payloadKind, typePayload, payloadField)]:
				var loweredType = lowerType(type, typePayload);
				loweredType == null || field != payloadField ? null : NativeLayoutQuery(lowerNativeLayoutKind(payloadKind), loweredType, payloadField, span);
			case [ClosureCall(callee, arguments, span), SyntaxExpressionPayload.ClosureCall(calleePayload, argumentPayloads)]:
				var loweredCallee = lowerExpression(callee, calleePayload), loweredArguments = lowerExpressionList(arguments, argumentPayloads);
				loweredCallee == null || loweredArguments == null ? null : ClosureCall(loweredCallee, loweredArguments, span);
			case [MethodCall(object, name, arguments, span), SyntaxExpressionPayload.MethodCall(objectPayload, payloadName, argumentPayloads)]:
				var loweredObject = lowerExpression(object, objectPayload), loweredArguments = lowerExpressionList(arguments, argumentPayloads);
				loweredObject == null || loweredArguments == null ? null : MethodCall(loweredObject, payloadName, loweredArguments, span);
			case [New(typeName, arguments, span), SyntaxExpressionPayload.New(payloadTypeName, argumentPayloads)]:
				var loweredArguments = lowerExpressionList(arguments, argumentPayloads);
				loweredArguments == null || typeName != payloadTypeName ? null : New(payloadTypeName, loweredArguments, span);
			case [NewGeneric(typeName, typeArguments, arguments, span), SyntaxExpressionPayload.NewGeneric(payloadTypeName, typeArgumentPayloads, argumentPayloads)]:
				var loweredTypes = lowerTypeList(typeArguments, typeArgumentPayloads), loweredArguments = lowerExpressionList(arguments, argumentPayloads);
				loweredTypes == null || loweredArguments == null || typeName != payloadTypeName ? null : NewGeneric(payloadTypeName, loweredTypes, loweredArguments, span);
			case [NewArray(element, length, span), SyntaxExpressionPayload.NewArray(elementPayload, lengthPayload)]:
				var loweredElement = lowerType(element, elementPayload), loweredLength = lowerExpression(length, lengthPayload);
				loweredElement == null || loweredLength == null ? null : NewArray(loweredElement, loweredLength, span);
			case [NewMap(key, value, span), SyntaxExpressionPayload.NewMap(keyPayload, valuePayload)]:
				var loweredKey = lowerType(key, keyPayload), loweredValue = lowerType(value, valuePayload);
				loweredKey == null || loweredValue == null ? null : NewMap(loweredKey, loweredValue, span);
			case [Index(array, index, span), SyntaxExpressionPayload.Index(arrayPayload, indexPayload)]:
				var loweredArray = lowerExpression(array, arrayPayload), loweredIndex = lowerExpression(index, indexPayload);
				loweredArray == null || loweredIndex == null ? null : Index(loweredArray, loweredIndex, span);
			case [PostfixIncrement(target, delta, span), SyntaxExpressionPayload.PostfixIncrement(targetPayload, payloadDelta)]:
				var loweredTarget = lowerExpression(target, targetPayload);
				loweredTarget == null || delta != payloadDelta ? null : PostfixIncrement(loweredTarget, payloadDelta, span);
			case [Lambda(arguments, statements, span), SyntaxExpressionPayload.Lambda(argumentPayloads, statementPayloads)]:
				var loweredArguments = lowerArguments(arguments, argumentPayloads), loweredStatements = lowerStatementList(statements, statementPayloads);
				loweredArguments == null || loweredStatements == null ? null : Lambda(loweredArguments, loweredStatements, span);
			default: null;
		};

	static function lowerExpressionList(direct:Array<AstExpression>, payload:Array<SyntaxExpressionPayload>):Null<Array<AstExpression>> {
		if (direct.length != payload.length)
			return null;
		var result:Array<AstExpression> = [];
		for (index in 0...direct.length) {
			var lowered = lowerExpression(direct[index], payload[index]);
			if (lowered == null)
				return null;
			result.push(lowered);
		}
		return result;
	}

	static function lowerArguments(direct:Array<AstArgument>, payload:Array<compiler.syntax.SyntaxTree.SyntaxArgumentPayload>):Null<Array<AstArgument>> {
		if (direct.length != payload.length)
			return null;
		var result:Array<AstArgument> = [];
		for (index in 0...direct.length) {
			var argument = direct[index], payloadArgument = payload[index], loweredType = lowerType(argument.type, payloadArgument.type), loweredDefault = argument.defaultValue == null ? null : lowerExpression(argument.defaultValue, payloadArgument.defaultValue);
			if (loweredType == null || argument.name != payloadArgument.name || argument.optional != payloadArgument.optional
				|| argument.defaultValue != null && loweredDefault == null || argument.defaultValue == null && payloadArgument.defaultValue != null)
				return null;
			result.push({name: payloadArgument.name, type: loweredType, span: argument.span, optional: payloadArgument.optional, defaultValue: loweredDefault});
		}
		return result;
	}

	static function lowerObjectFields(direct:Array<compiler.syntax.Ast.AstObjectField>, payload:Array<compiler.syntax.SyntaxTree.SyntaxObjectFieldPayload>):Null<Array<compiler.syntax.Ast.AstObjectField>> {
		if (direct.length != payload.length)
			return null;
		var result:Array<compiler.syntax.Ast.AstObjectField> = [];
		for (index in 0...direct.length) {
			var field = direct[index], payloadField = payload[index], loweredValue = lowerExpression(field.value, payloadField.value);
			if (loweredValue == null || field.name != payloadField.name)
				return null;
			result.push({name: payloadField.name, value: loweredValue, span: field.span});
		}
		return result;
	}

	static function lowerMapEntries(direct:Array<compiler.syntax.Ast.AstMapEntry>, payload:Array<compiler.syntax.SyntaxTree.SyntaxMapEntryPayload>):Null<Array<compiler.syntax.Ast.AstMapEntry>> {
		if (direct.length != payload.length)
			return null;
		var result:Array<compiler.syntax.Ast.AstMapEntry> = [];
		for (index in 0...direct.length) {
			var entry = direct[index], payloadEntry = payload[index], loweredKey = lowerExpression(entry.key, payloadEntry.key), loweredValue = lowerExpression(entry.value, payloadEntry.value);
			if (loweredKey == null || loweredValue == null)
				return null;
			result.push({key: loweredKey, value: loweredValue, span: entry.span});
		}
		return result;
	}

	static function lowerSwitchExpressionCases(direct:Array<compiler.syntax.Ast.AstSwitchExpressionCase>, payload:Array<compiler.syntax.SyntaxTree.SyntaxSwitchExpressionCasePayload>):Null<Array<compiler.syntax.Ast.AstSwitchExpressionCase>> {
		if (direct.length != payload.length)
			return null;
		var result:Array<compiler.syntax.Ast.AstSwitchExpressionCase> = [];
		for (index in 0...direct.length) {
			var entry = direct[index], payloadEntry = payload[index], loweredValue = lowerExpression(entry.value, payloadEntry.value), loweredGuard = entry.guard == null ? null : lowerExpression(entry.guard, payloadEntry.guard), loweredResult = lowerExpression(entry.result, payloadEntry.result);
			if (loweredValue == null || entry.guard != null && loweredGuard == null || loweredResult == null)
				return null;
			result.push({value: loweredValue, guard: loweredGuard, result: loweredResult, span: entry.span});
		}
		return result;
	}

	static function lowerNativeLayoutKind(kind:compiler.syntax.SyntaxTree.SyntaxNativeLayoutQueryKind):compiler.syntax.Ast.NativeLayoutQueryKind
		return switch kind {
			case compiler.syntax.SyntaxTree.SyntaxNativeLayoutQueryKind.SizeOf: compiler.syntax.Ast.NativeLayoutQueryKind.SizeOf;
			case compiler.syntax.SyntaxTree.SyntaxNativeLayoutQueryKind.AlignOf: compiler.syntax.Ast.NativeLayoutQueryKind.AlignOf;
			case compiler.syntax.SyntaxTree.SyntaxNativeLayoutQueryKind.OffsetOf: compiler.syntax.Ast.NativeLayoutQueryKind.OffsetOf;
		};

	static function lowerBinary(expected:compiler.syntax.SyntaxTree.SyntaxBinaryOperator, left:AstExpression, right:AstExpression,
			span:SourceSpan, operation:compiler.syntax.SyntaxTree.SyntaxBinaryOperator, leftPayload:SyntaxExpressionPayload,
			rightPayload:SyntaxExpressionPayload):Null<AstExpression> {
		if (operation != expected)
			return null;
		var loweredLeft = lowerExpression(left, leftPayload), loweredRight = lowerExpression(right, rightPayload);
		if (loweredLeft == null || loweredRight == null)
			return null;
		return switch expected {
			case compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Add: Add(loweredLeft, loweredRight, span);
			case compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Sub: Sub(loweredLeft, loweredRight, span);
			case compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Mul: Mul(loweredLeft, loweredRight, span);
			case compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Div: Div(loweredLeft, loweredRight, span);
			case compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Mod: Mod(loweredLeft, loweredRight, span);
			case compiler.syntax.SyntaxTree.SyntaxBinaryOperator.BitAnd: BitAnd(loweredLeft, loweredRight, span);
			case compiler.syntax.SyntaxTree.SyntaxBinaryOperator.BitXor: BitXor(loweredLeft, loweredRight, span);
			case compiler.syntax.SyntaxTree.SyntaxBinaryOperator.BitOr: BitOr(loweredLeft, loweredRight, span);
			case compiler.syntax.SyntaxTree.SyntaxBinaryOperator.ShiftLeft: ShiftLeft(loweredLeft, loweredRight, span);
			case compiler.syntax.SyntaxTree.SyntaxBinaryOperator.ShiftRight: ShiftRight(loweredLeft, loweredRight, span);
			case compiler.syntax.SyntaxTree.SyntaxBinaryOperator.UnsignedShiftRight: UnsignedShiftRight(loweredLeft, loweredRight, span);
			case compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Less: Less(loweredLeft, loweredRight, span);
			case compiler.syntax.SyntaxTree.SyntaxBinaryOperator.LessEqual: LessEqual(loweredLeft, loweredRight, span);
			case compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Greater: Greater(loweredLeft, loweredRight, span);
			case compiler.syntax.SyntaxTree.SyntaxBinaryOperator.GreaterEqual: GreaterEqual(loweredLeft, loweredRight, span);
			case compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Equal: Equal(loweredLeft, loweredRight, span);
			case compiler.syntax.SyntaxTree.SyntaxBinaryOperator.NotEqual: NotEqual(loweredLeft, loweredRight, span);
			case compiler.syntax.SyntaxTree.SyntaxBinaryOperator.And: And(loweredLeft, loweredRight, span);
			case compiler.syntax.SyntaxTree.SyntaxBinaryOperator.Or: Or(loweredLeft, loweredRight, span);
		};
	}

	static function lowerUnary(expected:compiler.syntax.SyntaxTree.SyntaxUnaryOperator, value:AstExpression, span:SourceSpan,
			operation:compiler.syntax.SyntaxTree.SyntaxUnaryOperator, valuePayload:SyntaxExpressionPayload):Null<AstExpression> {
		if (operation != expected)
			return null;
		var loweredValue = lowerExpression(value, valuePayload);
		return loweredValue == null ? null : switch expected {
			case compiler.syntax.SyntaxTree.SyntaxUnaryOperator.Negate: Negate(loweredValue, span);
			case compiler.syntax.SyntaxTree.SyntaxUnaryOperator.Not: Not(loweredValue, span);
		};
	}

	static function statementSpan(statement:AstStatement):SourceSpan
		return switch statement {
			case ErrorStatement(span): span;
			case UninitializedDeclaration(_, _, span), VarDeclaration(_, _, _, span), Assignment(_, _, span), IndexAssignment(_, _, _, span),
				FieldAssignment(_, _, _, span), Return(_, span), ReturnVoid(span), Throw(_, span), Try(_, _, span), If(_, _, _, span), While(_, _, span),
				DoWhile(_, _, span), ForIn(_, _, _, _, span), Break(span), Continue(span), Switch(_, _, _, _, span), Increment(_, _, span), Expression(_, span): span;
		};

	static function lowerSimpleType(name:Null<String>):Null<AstType>
		return name == null ? null : switch name {
			case "Int": IntType;
			case "Bool": BoolType;
			case "Float": FloatType;
			case "String": StringType;
			case "Void": VoidType;
			case "?": InferredType;
			default: NamedType(name);
		};

	static function fieldAccessName(access:Null<AstFieldAccess>):Null<String>
		return access == null ? null : switch access {
			case DefaultAccess: "default";
			case NullAccess: "null";
			case NeverAccess: "never";
			case GetAccess: "get";
			case SetAccess: "set";
			case DynamicAccess: "dynamic";
		};

	static function lowerFieldAccess(name:Null<String>):Null<AstFieldAccess>
		return name == null ? null : switch name {
			case "default": DefaultAccess;
			case "null": NullAccess;
			case "never": NeverAccess;
			case "get": GetAccess;
			case "set": SetAccess;
			case "dynamic": DynamicAccess;
			default: null;
		};

	static function simpleTypeMatches(type:Null<AstType>, name:Null<String>):Bool
		return switch type {
			case null: name == null;
			case NamedType(value): name == value;
			default: false;
		};

	static function validateSpans(tree:SyntaxTree):Void {
		for (node in tree.grammarNodes()) {
			if (node.span.file != tree.source || node.span.start < 0 || node.span.end < node.span.start
				|| node.span.end > tree.source.bytes.length)
				throw 'CST node ${node.kind} has an invalid source span';
		}
	}

	static function validateDeclarations(tree:SyntaxTree, program:AstProgram):Void {
		var nodes = tree.grammarNodes();
		if (program.packageName != null)
			requireNode(nodes, SyntaxKind.PackageDeclaration, 1, "package declaration");
		requireNode(nodes, SyntaxKind.ImportDeclaration, program.imports.length, "import declarations");
		requireNode(nodes, SyntaxKind.TypeAliasDeclaration, program.aliases.length, "type aliases");
		requireNode(nodes, SyntaxKind.EnumDeclaration, program.enums.length, "enum declarations");
		requireNode(nodes, SyntaxKind.EnumAbstractDeclaration, program.enumAbstracts.length, "enum abstract declarations");
		requireNode(nodes, SyntaxKind.AbstractDeclaration, program.abstracts.length, "abstract declarations");
		requireNode(nodes, SyntaxKind.InterfaceDeclaration, program.interfaces.length, "interface declarations");
		requireNode(nodes, SyntaxKind.ClassDeclaration, program.classes.length, "class declarations");
		requireNode(nodes, SyntaxKind.FunctionDeclaration, program.functions.length + methodCount(program), "function declarations");
	}

	static function methodCount(program:AstProgram):Int {
		var count = 0;
		for (classDeclaration in program.classes)
			count += classDeclaration.methods.length;
		for (interfaceDeclaration in program.interfaces)
			count += interfaceDeclaration.methods.length;
		for (abstractDeclaration in program.abstracts)
			count += abstractDeclaration.methods.length;
		return count;
	}

	static function requireNode(nodes:Array<SyntaxNode>, kind:SyntaxKind, expected:Int, label:String):Void {
		if (expected == 0)
			return;
		var actual = 0;
		for (node in nodes)
			if (node.kind == kind)
				actual++;
		if (actual < expected)
			throw 'CST/AST lowering mismatch for $label: expected at least $expected, got $actual';
	}

	static function keepOrFallback<T>(lowered:Null<T>, direct:T, label:String):T {
		if (lowered == null && requireComplete)
			throw 'CST lowering could not independently reconstruct $label';
		return lowered == null ? direct : lowered;
	}
}
