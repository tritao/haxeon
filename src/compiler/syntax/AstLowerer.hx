package compiler.syntax;

import compiler.syntax.Ast.AstProgram;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstInterface;
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
import compiler.syntax.SyntaxTree.SyntaxTree;

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
	public static function lower(tree:SyntaxTree, direct:AstProgram):AstProgram {
		validateSpans(tree);
		validateDeclarations(tree, direct);
		return lowerHeader(tree, direct);
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
				case SyntaxNodePayload.ClassHeader(_, _, _, _, _, _):
				case SyntaxNodePayload.FieldHeader(_, _, _, _, _, _, _):
				case SyntaxNodePayload.FunctionHeader(_, _, _, _, _, _):
				case SyntaxNodePayload.Statement(_):
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
			aliases: direct.aliases,
			enums: direct.enums,
			enumAbstracts: direct.enumAbstracts,
			abstracts: direct.abstracts,
			interfaces: lowerInterfaces(tree, direct.interfaces),
			classes: lowerClasses(tree, direct.classes),
			functions: lowerFunctions(tree, direct.functions)
		};
	}

	static function lowerInterfaces(tree:SyntaxTree, direct:Array<AstInterface>):Array<AstInterface> {
		var nodePayloads = collectPayloads(tree), result:Array<AstInterface> = [];
		for (interfaceDeclaration in direct) {
			result.push({
				name: interfaceDeclaration.name,
				typeParameters: interfaceDeclaration.typeParameters,
				typeConstraints: interfaceDeclaration.typeConstraints,
				bases: interfaceDeclaration.bases,
				methods: lowerFunctionsFromPayloads(interfaceDeclaration.methods, nodePayloads),
				span: interfaceDeclaration.span
			});
		}
		return result;
	}

	static function lowerFunctions(tree:SyntaxTree, direct:Array<AstFunction>):Array<AstFunction>
		return lowerFunctionsFromPayloads(direct, collectPayloads(tree));

	static function lowerFunctionsFromPayloads(direct:Array<AstFunction>, nodePayloads:Map<Int, SyntaxNodePayload>):Array<AstFunction> {
		var result:Array<AstFunction> = [];
		for (functionDeclaration in direct) {
			var lowered = lowerFunction(functionDeclaration, nodePayloads.get(functionDeclaration.span.start), nodePayloads);
			result.push(lowered == null ? functionDeclaration : lowered);
		}
		return result;
	}

	static function lowerClasses(tree:SyntaxTree, direct:Array<AstClass>):Array<AstClass> {
		var nodePayloads = collectPayloads(tree);
		var headers:Map<Int, {name:String, isPrivate:Bool, isExtern:Bool, typeParameters:Array<String>, baseName:Null<String>, interfaceNames:Array<Null<String>>}> = [];
		for (node in tree.grammarNodes())
			switch node.payload {
				case SyntaxNodePayload.ClassHeader(name, isPrivate, isExtern, typeParameters, baseName, interfaceNames):
					headers.set(node.span.start, {
						name: name,
						isPrivate: isPrivate,
						isExtern: isExtern,
						typeParameters: typeParameters,
						baseName: baseName,
						interfaceNames: interfaceNames
					});
				case SyntaxNodePayload.PackageName(_), SyntaxNodePayload.Import(_, _), SyntaxNodePayload.FieldHeader(_, _, _, _, _, _, _),
					SyntaxNodePayload.FunctionHeader(_, _, _, _, _, _), SyntaxNodePayload.Statement(_), null:
			}
		var result:Array<AstClass> = [];
		for (classDeclaration in direct) {
			var header = headers.get(classDeclaration.span.start);
			var fields = lowerFields(classDeclaration.fields, nodePayloads),
				methods = lowerFunctionsFromPayloads(classDeclaration.methods, nodePayloads),
				name = classDeclaration.name,
				isExtern = classDeclaration.isExtern,
				typeParameters = classDeclaration.typeParameters,
				typeConstraints = classDeclaration.typeConstraints,
				isPrivate = classDeclaration.isPrivate,
				base = classDeclaration.base,
				interfaces = classDeclaration.interfaces;
			if (header != null && isLowerableClassHeader(classDeclaration, header)) {
				name = header.name;
				isExtern = header.isExtern;
				typeParameters = header.typeParameters;
				typeConstraints = [];
				isPrivate = header.isPrivate;
				base = header.baseName == null ? null : NamedType(header.baseName);
				interfaces = [for (interfaceName in header.interfaceNames) NamedType(interfaceName)];
			}
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

	static function isLowerableClassHeader(classDeclaration:AstClass,
			header:{name:String, isPrivate:Bool, isExtern:Bool, typeParameters:Array<String>, baseName:Null<String>, interfaceNames:Array<Null<String>>}):Bool {
		if (classDeclaration.typeParameters.length != header.typeParameters.length
			|| (classDeclaration.typeConstraints != null && classDeclaration.typeConstraints.length > 0)
			|| !simpleTypeMatches(classDeclaration.base, header.baseName)
			|| classDeclaration.interfaces.length != header.interfaceNames.length)
			return false;
		for (index in 0...classDeclaration.typeParameters.length)
			if (classDeclaration.typeParameters[index] != header.typeParameters[index])
				return false;
		for (index in 0...classDeclaration.interfaces.length) {
			var interfaceName = header.interfaceNames[index];
			if (interfaceName == null || !simpleTypeMatches(classDeclaration.interfaces[index], interfaceName))
				return false;
		}
		return true;
	}

	static function collectPayloads(tree:SyntaxTree):Map<Int, SyntaxNodePayload> {
		var result:Map<Int, SyntaxNodePayload> = [];
		for (node in tree.grammarNodes())
			switch node.payload {
				case null:
				case SyntaxNodePayload.PackageName(_), SyntaxNodePayload.Import(_, _), SyntaxNodePayload.ClassHeader(_, _, _, _, _, _),
					SyntaxNodePayload.FieldHeader(_, _, _, _, _, _, _), SyntaxNodePayload.FunctionHeader(_, _, _, _, _, _),
					SyntaxNodePayload.Statement(_):
					result.set(node.span.start, node.payload);
			}
		return result;
	}

	static function lowerFields(direct:Array<AstField>, nodePayloads:Map<Int, SyntaxNodePayload>):Array<AstField> {
		var result:Array<AstField> = [];
		for (field in direct) {
			var lowered:Null<AstField> = switch nodePayloads.get(field.span.start) {
				case SyntaxNodePayload.FieldHeader(name, typeName, isStatic, isInline, isFinal, readAccess, writeAccess):
					lowerField(field, name, typeName, isStatic, isInline, isFinal, readAccess, writeAccess);
				default: null;
			};
			result.push(lowered == null ? field : lowered);
		}
		return result;
	}

	static function lowerField(field:AstField, name:String, typeName:Null<String>, isStatic:Bool, isInline:Bool, isFinal:Bool,
			readAccess:Null<String>, writeAccess:Null<String>):Null<AstField> {
		if (field.initializer != null || typeName == null || !simpleTypeMatches(field.type, typeName)
			|| field.isStatic != isStatic || field.isInline != isInline || field.isFinal != isFinal
			|| fieldAccessName(field.readAccess) != readAccess || fieldAccessName(field.writeAccess) != writeAccess)
			return null;
		return {
			name: name,
			type: lowerSimpleType(typeName),
			initializer: null,
			readAccess: lowerFieldAccess(readAccess),
			writeAccess: lowerFieldAccess(writeAccess),
			isStatic: isStatic,
			isInline: isInline,
			isFinal: isFinal,
			span: field.span
		};
	}

	static function lowerFunction(functionDeclaration:AstFunction, payload:Null<SyntaxNodePayload>,
			nodePayloads:Map<Int, SyntaxNodePayload>):Null<AstFunction> {
		return switch payload {
			case SyntaxNodePayload.FunctionHeader(name, isStatic, isExtern, typeParameters, parameters, resultTypeName):
				var directTypeParameters = functionDeclaration.typeParameters == null ? [] : functionDeclaration.typeParameters,
					loweredStatements = lowerStatements(functionDeclaration.statements, nodePayloads);
				if (loweredStatements == null || functionDeclaration.metadata != null && functionDeclaration.metadata.length > 0
					|| functionDeclaration.typeConstraints != null && functionDeclaration.typeConstraints.length > 0
					|| resultTypeName == null || !simpleTypeMatches(functionDeclaration.result, resultTypeName)
					|| functionDeclaration.arguments.length != parameters.length
					|| functionDeclaration.name != name || functionDeclaration.isStatic != isStatic
					|| (functionDeclaration.isExtern == true) != isExtern
					|| directTypeParameters.length != typeParameters.length)
					null;
				else {
					var loweredArguments:Array<AstArgument> = [];
					var valid = true;
					for (index in 0...directTypeParameters.length)
						if (directTypeParameters[index] != typeParameters[index])
							valid = false;
					for (index in 0...parameters.length) {
						var sourceArgument = functionDeclaration.arguments[index], parameter = parameters[index];
						if (sourceArgument.defaultValue != null || parameter.typeName == null
							|| sourceArgument.name != parameter.name || sourceArgument.optional != parameter.optional
							|| !simpleTypeMatches(sourceArgument.type, parameter.typeName)) {
							valid = false;
							break;
						}
						loweredArguments.push({
							name: parameter.name,
							type: lowerSimpleType(parameter.typeName),
							span: sourceArgument.span,
							optional: parameter.optional,
							defaultValue: null
						});
					}
					if (!valid)
						null;
					else
						{
							name: name,
							isStatic: isStatic,
							isExtern: isExtern,
							metadata: [],
							typeParameters: typeParameters,
							typeConstraints: [],
							arguments: loweredArguments,
							result: lowerSimpleType(resultTypeName),
							statements: loweredStatements,
							span: functionDeclaration.span
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
			default: null;
		};

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

	static function lowerExpression(expression:AstExpression, payload:SyntaxExpressionPayload):Null<AstExpression>
		return switch [expression, payload] {
			case [IntegerLiteral(_, span), SyntaxExpressionPayload.Integer(value)]: IntegerLiteral(value, span);
			case [FloatLiteral(_, span), SyntaxExpressionPayload.Float(value)]: FloatLiteral(value, span);
			case [StringLiteral(_, span), SyntaxExpressionPayload.String(value)]: StringLiteral(value, span);
			case [BoolLiteral(_, span), SyntaxExpressionPayload.Bool(value)]: BoolLiteral(value, span);
			case [NullLiteral(span), SyntaxExpressionPayload.NullValue]: NullLiteral(span);
			case [Variable(_, span), SyntaxExpressionPayload.Variable(name)]: Variable(name, span);
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
			default: null;
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
}
