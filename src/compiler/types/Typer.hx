package compiler.types;

import compiler.Ast;
import compiler.Ast.AstExpression;
import compiler.Ast.AstFunction;
import compiler.Ast.AstProgram;
import compiler.Ast.AstStatement;
import compiler.Ast.AstType;
import compiler.Ast.AstClass;
import compiler.Ast.AstInterface;
import compiler.Ast.AstEnum;
import compiler.types.Type.CompilerType;
import compiler.types.RuntimeType;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedClass;
import compiler.types.TypedAst.TypedCatch;
import compiler.types.TypedAst.TypedField;
import compiler.types.TypedAst.TypedProgram;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.TypedAst.TypedSwitchBinding;
import compiler.types.TypedAst.TypedSwitchCase;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceSpan;

class Typer {
	final signatures:Map<String, AstFunction> = [];
	final methodInfo:Map<String, {owner:String, isStatic:Bool, isConstructor:Bool}> = [];
	final externals:Map<String, {arguments:Array<CompilerType>, result:CompilerType}>;
	var classDecls:Map<String, AstClass> = [];
	var interfaceDecls:Map<String, AstInterface> = [];
	var enumDecls:Map<String, AstEnum> = [];
	var declarations:DeclarationIndex;
	var relations:TypeRelations;
	final generated:Array<TypedFunction> = [];
	final generatedClasses:Array<TypedClass> = [];
	final lambdaCache:Map<String, TypedExpression> = [];
	var currentFunctionName:String = "";
	var currentAssigned:Map<String, Bool> = [];
	var currentCells:Map<String, String> = [];
	var currentCellTypes:Map<String, CompilerType> = [];
	var loopDepth:Int = 0;

	public static function type(program:AstProgram):TypedProgram
		return new Typer(null).typeProgram(program, null, true);

	/** Type a reusable module without requiring an executable main function. */
	public static function typeLibrary(program:AstProgram):TypedProgram
		return new Typer(null).typeProgram(program, null, false);

	public static function typeSelected(program:AstProgram, selected:Map<String, Bool>,
			?externals:Map<String, {arguments:Array<CompilerType>, result:CompilerType}>):TypedProgram
		return new Typer(externals).typeProgram(program, selected, true);

	function new(externals)
		this.externals = externals == null ? [] : externals;

	function typeProgram(program:AstProgram, selected:Null<Map<String, Bool>>, requireMain:Bool):TypedProgram {
		declarations = new DeclarationIndex(program);
		relations = new TypeRelations(declarations);
		enumDecls = declarations.enums;
		interfaceDecls = declarations.interfaces;
		classDecls = declarations.classes;
		for (interfaceDecl in program.interfaces) {
			for (method in interfaceDecl.methods) {
				var qualified = interfaceDecl.name + "." + method.name;
				if (signatures.exists(qualified))
					fail("E1000", 'Duplicate interface method "$qualified"', method.span);
				signatures.set(qualified, method);
				methodInfo.set(qualified, {owner: interfaceDecl.name, isStatic: false, isConstructor: false});
			}
		}
		for (classDecl in program.classes) {
			for (method in classDecl.methods) {
				var qualified = classDecl.name + "." + method.name;
				if (signatures.exists(qualified))
					fail("E1000", 'Duplicate method "$qualified"', method.span);
				signatures.set(qualified, method);
				methodInfo.set(qualified, {
					owner: classDecl.name,
					isStatic: method.isStatic,
					isConstructor: method.name == "new"
				});
			}
		}
		for (fn in program.functions) {
			if (signatures.exists(fn.name))
				fail("E1000", 'Duplicate function "${fn.name}"', fn.span);
			if (externals.exists(fn.name))
				fail("E1000", 'Function "${fn.name}" conflicts with a registered native', fn.span);
			signatures.set(fn.name, fn);
		}
		if (requireMain) {
			var main = signatures.get("main");
			if (main == null || main.arguments.length != 0 || lowerType(main.result) != TInt)
				throw "Program must define function main():Int";
		}
		var typedEnums = [
			for (enumDecl in program.enums)
				{
					name: enumDecl.name,
					cases: [
						for (caseDecl in enumDecl.cases)
							{
								name: caseDecl.name,
								params: [for (param in caseDecl.params) lowerType(param)],
								span: caseDecl.span
							}
					],
					span: enumDecl.span
				}
		], typedInterfaces = [
			for (interfaceDecl in program.interfaces)
				{
					name: interfaceDecl.name,
					bases: interfaceDecl.bases,
					methods: [
						for (method in interfaceDecl.methods)
							{name: method.name, arguments: [for (argument in method.arguments) lowerType(argument.type)], result: lowerType(method.result)}
					]
				}
			], typedClasses = [for (classDecl in program.classes) typeClass(classDecl, classDecls)], typedFunctions:Array<TypedFunction> = [];
		for (fn in program.functions)
			if (selected == null || selected.exists(fn.name))
				typedFunctions.push(typeFunction(fn));
		for (classDecl in typedClasses)
			for (method in classDecl.methods)
				if (selected == null || selected.exists(method.name))
					typedFunctions.push(method);
		for (lambda in generated)
			typedFunctions.push(lambda);
		return {
			enums: typedEnums,
			interfaces: typedInterfaces,
			classes: typedClasses.concat(generatedClasses),
			functions: typedFunctions
		};
	}

	function typeClass(classDecl:AstClass, classes:Map<String, AstClass>):TypedClass {
		var fields:Array<TypedField> = [], fieldNames:Map<String, Bool> = [];
		for (field in classDecl.fields) {
			if (fieldNames.exists(field.name))
				fail("E1000", 'Duplicate field "${classDecl.name}.${field.name}"', field.span);
			var type = lowerType(field.type);
			if (type == TVoid)
				fail("E1002", 'Field "${classDecl.name}.${field.name}" cannot have type Void', field.span);
			var initializer:Null<TypedExpression> = null;
			if (field.initializer != null) {
				var previousFunctionName = currentFunctionName;
				currentFunctionName = classDecl.name + ".__init";
				var scope = new Scope();
				if (!field.isStatic)
					scope.define("this", TClass(classDecl.name), field.span);
				initializer = coerce(typeExpression(field.initializer, scope), type,
					(field.isStatic ? 'static field "${classDecl.name}.${field.name}"' : 'field "${classDecl.name}.${field.name}"'), "E1002");
				currentFunctionName = previousFunctionName;
			}
			fieldNames.set(field.name, true);
			fields.push({
				name: field.name,
				type: type,
				initializer: initializer,
				isStatic: field.isStatic,
				isFinal: field.isFinal,
				span: field.span
			});
		}
		for (interfaceName in classDecl.interfaces) {
			if (!interfaceDecls.exists(interfaceName))
				fail("E1007", 'Unknown interface "$interfaceName"', classDecl.span);
			validateInterfaceImplementation(classDecl, interfaceName, classDecl.span);
		}
		var typedMethods:Array<TypedFunction> = [],
			instanceInitializers:Array<TypedField> = [],
			hasConstructor = false;
		for (field in fields)
			if (!field.isStatic && field.initializer != null)
				instanceInitializers.push(field);
		for (method in classDecl.methods) {
			var typedMethod = typeFunction(method, classDecl.name, method.isStatic);
			if (method.name == "new") {
				hasConstructor = true;
				if (instanceInitializers.length > 0)
					typedMethod = prependInstanceInitializers(typedMethod, classDecl.name, instanceInitializers);
			}
			typedMethods.push(typedMethod);
		}
		if (!hasConstructor && instanceInitializers.length > 0)
			typedMethods.push({
				name: classDecl.name + ".new",
				owner: classDecl.name,
				isStatic: false,
				isConstructor: true,
				arguments: [],
				result: TVoid,
				statements: [
					for (field in instanceInitializers)
						TFieldAssign(new TypedExpression(TLocal("this"), TClass(classDecl.name), field.span), field.name, field.initializer, field.span)
				],
				cells: [],
				cellCaptures: [],
				span: classDecl.span
			});
		return {
			name: classDecl.name,
			base: classDecl.base,
			interfaces: classDecl.interfaces,
			fields: fields,
			methods: typedMethods,
			span: classDecl.span
		};
	}

	function prependInstanceInitializers(method:TypedFunction, className:String, fields:Array<TypedField>):TypedFunction {
		var statements:Array<TypedStatement> = [
			for (field in fields)
				TFieldAssign(new TypedExpression(TLocal("this"), TClass(className), field.span), field.name, field.initializer, field.span)
		];
		return {
			name: method.name,
			owner: method.owner,
			isStatic: method.isStatic,
			isConstructor: method.isConstructor,
			arguments: method.arguments,
			result: method.result,
			statements: statements.concat(method.statements),
			cells: method.cells,
			cellCaptures: method.cellCaptures,
			span: method.span
		};
	}

	function validateInterfaceImplementation(classDecl:AstClass, interfaceName:String, span:SourceSpan):Void {
		var interfaceDecl = interfaceDecls.get(interfaceName);
		if (interfaceDecl == null)
			return;
		for (base in interfaceDecl.bases) {
			if (!interfaceDecls.exists(base))
				fail("E1007", 'Unknown interface "$base"', span);
			validateInterfaceImplementation(classDecl, base, span);
		}
		for (method in interfaceDecl.methods) {
			var implementation = findMethod(classDecl.name, method.name);
			if (implementation == null || implementation.isStatic)
				fail("E1007", 'Class "${classDecl.name}" does not implement "$interfaceName.${method.name}"', span);
			var actual = signatures.get(implementation.owner + "." + method.name);
			if (actual == null || !sameSignature(actual, method))
				fail("E1003", 'Method "${classDecl.name}.${method.name}" does not match interface "$interfaceName"', span);
		}
	}

	function sameSignature(left:AstFunction, right:AstFunction):Bool {
		if (left.arguments.length != right.arguments.length || !TypeRelations.equals(lowerType(left.result), lowerType(right.result)))
			return false;
		for (i in 0...left.arguments.length)
			if (!TypeRelations.equals(lowerType(left.arguments[i].type), lowerType(right.arguments[i].type)))
				return false;
		return true;
	}

	function typeFunction(fn:AstFunction, ?owner:String, isStatic:Bool = false):TypedFunction {
		Scope.resetLocalIds();
		var previousFunctionName = currentFunctionName;
		var previousAssigned = currentAssigned;
		var previousCells = currentCells;
		var previousCellTypes = currentCellTypes;
		currentFunctionName = owner == null ? fn.name : owner + "." + fn.name;
		currentAssigned = [];
		collectAssignedLocals(fn.statements, currentAssigned);
		currentCells = [];
		currentCellTypes = [];
		var declared:Map<String, Bool> = [];
		for (argument in fn.arguments)
			declared.set(argument.name, true);
		collectDeclaredLocals(fn.statements, declared);
		var mutableCandidates:Map<String, Bool> = [];
		collectMutableCaptureCandidates(fn.statements, declared, mutableCandidates);
		collectExceptionCellCandidates(fn.statements, declared, mutableCandidates);
		for (name in mutableCandidates.keys())
			currentCells.set(name, '$' + 'cell:' + currentFunctionName + ':' + name);
		var scope = new Scope();
		var isConstructor = owner != null && fn.name == "new";
		if (owner != null && !isStatic)
			scope.define("this", TClass(owner), fn.span);
		var arguments = [];
		for (argument in fn.arguments) {
			var type = lowerType(argument.type);
			scope.define(argument.name, type, argument.span);
			if (currentCells.exists(argument.name))
				currentCellTypes.set(argument.name, type);
			arguments.push({name: currentCells.exists(argument.name) ? argument.name : scope.resolveId(argument.name), type: type});
		}
		var result = lowerType(fn.result);
		var statements = typeStatements(fn.statements, scope, result);
		if (result != TVoid && !alwaysReturns(statements))
			fail("E1006", 'Function ${fn.name} does not return on every path', fn.span);
		var resultFunction:TypedFunction = {
			name: owner == null ? fn.name : owner + "." + fn.name,
			owner: owner,
			isStatic: isStatic,
			isConstructor: isConstructor,
			arguments: arguments,
			result: result,
			statements: statements,
			cells: currentCells.copy(),
			cellCaptures: [],
			span: fn.span
		};
		for (name in currentCells.keys()) {
			var cellType = currentCellTypes.get(name);
			if (cellType != null)
				generatedClasses.push({
					name: currentCells.get(name),
					base: null,
					interfaces: [],
					fields: [
						{
							name: "value",
							type: cellType,
							initializer: null,
							isStatic: false,
							isFinal: false,
							span: fn.span
						}
					],
					methods: [],
					span: fn.span
				});
		}
		currentFunctionName = previousFunctionName;
		currentAssigned = previousAssigned;
		currentCells = previousCells;
		currentCellTypes = previousCellTypes;
		return resultFunction;
	}

	function typeStatements(statements:Array<AstStatement>, scope:Scope, result:CompilerType):Array<TypedStatement> {
		var output = [];
		for (statement in statements) {
			if (alwaysReturns(output))
				fail("E1012", "Unreachable statement", statementSpan(statement));
			switch statement {
				case VarDeclaration(name, declared, initializer, span):
					var value = typeExpression(initializer, scope);
					if (declared != null) {
						var expected = lowerType(declared);
						value = coerce(value, expected, 'local "$name"', "E1002");
					} else if (sameType(value.type, TNull)) {
						fail("E1002", 'Null requires an explicit nullable type for local "$name"', span);
					}
					scope.define(name, value.type, span);
					if (currentCells.exists(name))
						currentCellTypes.set(name, value.type);
					output.push(TVar(currentCells.exists(name) ? name : scope.resolveId(name), value, span));
				case Return(expression, span):
					var value = typeExpression(expression, scope);
					value = coerce(value, result, "return", "E1003");
					output.push(TReturn(value, span));
				case ReturnVoid(span):
					if (result != TVoid)
						fail("E1003", "Return type mismatch", span);
					output.push(TReturnVoid(span));
				case Throw(expression, span):
					var value = typeExpression(expression, scope);
					if (sameType(value.type, TVoid))
						fail("E1021", "Cannot throw a Void value", span);
					if (sameType(value.type, TNull))
						fail("E1021", "Cannot throw null", span);
					output.push(TThrow(value, span));
				case Try(tryBranch, catches, span):
					var typedCatches:Array<TypedCatch> = [];
					for (i in 0...catches.length) {
						var catchClause = catches[i],
							loweredCatchType = lowerType(catchClause.type);
						switch loweredCatchType {
							case TDynamic:
								if (i != catches.length - 1) fail("E1022", "Dynamic catch must be the final catch clause", catchClause.span);
							case TInt, TFloat, TBool, TString, TClass(_):
							default: fail("E1022", "Unsupported catch binding type", catchClause.span);
						}
						var catchScope = new Scope(scope);
						catchScope.define(catchClause.name, loweredCatchType, catchClause.span);
						typedCatches.push({
							name: catchScope.resolveId(catchClause.name),
							type: loweredCatchType,
							statements: typeStatements(catchClause.statements, catchScope, result),
							span: catchClause.span
						});
					}
					output.push(TTry(typeStatements(tryBranch, new Scope(scope), result), typedCatches, span));
				case Break(span):
					if (loopDepth == 0)
						fail("E1017", "break is only valid inside a loop", span);
					output.push(TBreak(span));
				case Continue(span):
					if (loopDepth == 0)
						fail("E1017", "continue is only valid inside a loop", span);
					output.push(TContinue(span));
				case Increment(name, delta, span):
					var current = scope.resolve(name);
					if (current == null) {
						var dot = name.indexOf("."),
							ownerSeparator = currentFunctionName.lastIndexOf("."),
							owner = dot < 0 ? (ownerSeparator < 0 ? null : currentFunctionName.substr(0, ownerSeparator)) : name.substr(0, dot),
							fieldName = dot < 0 ? name : name.substr(dot + 1),
							staticField = owner == null ? null : findStaticFieldNullable(owner, fieldName);
						if (staticField == null || (!sameType(staticField.type, TInt) && !sameType(staticField.type, TFloat)))
							fail("E1018", 'Increment requires a numeric local or static field "$name"', span);
						var oldValue = new TypedExpression(TStaticField(staticField.owner, fieldName), staticField.type, span),
							one:TypedExpression = sameType(staticField.type,
								TInt) ? new TypedExpression(TIntLiteral(1), TInt, span) : new TypedExpression(TFloatLiteral(1), TFloat, span),
							updated = delta > 0 ? new TypedExpression(TAdd(oldValue, one), staticField.type,
								span) : new TypedExpression(TSub(oldValue, one), staticField.type, span);
						output.push(TStaticFieldAssign(staticField.owner, fieldName, updated, span));
					} else if (!sameType(current, TInt) && !sameType(current, TFloat))
						fail("E1018", 'Increment requires a numeric local "$name"', span);
					else if (scope.isCapture(name)) {
						if (!scope.isCellCapture(name))
							fail("E1013", 'Captured variable "$name" requires mutable capture cells', span);
						output.push(TCellCapturedIncrement(name, scope.cellClass(name), current, delta, span));
					} else if (currentCells.exists(name))
						output.push(TCellIncrement(name, currentCells.get(name), current, delta, span));
					else
						output.push(TIncrement(scope.resolveId(name), delta, span));
				case Assignment(name, expression, span):
					var dot = name.indexOf("."),
						value = typeExpression(expression, scope);
					if (dot < 0) {
						var expected = scope.resolve(name);
						if (expected == null) {
							var ownerSeparator = currentFunctionName.lastIndexOf("."),
								owner = ownerSeparator < 0 ? null : currentFunctionName.substr(0, ownerSeparator),
								staticField = owner == null ? null : findStaticFieldNullable(owner, name);
							if (staticField == null)
								fail("E1005", 'Unknown variable "$name"', span);
							value = coerce(value, staticField.type, 'field "$name"', "E1002");
							output.push(TStaticFieldAssign(staticField.owner, name, value, span));
						} else {
							value = coerce(value, expected, 'local "$name"', "E1002");
							if (scope.isCapture(name)) {
								if (!scope.isCellCapture(name))
									fail("E1013", 'Captured variable "$name" requires mutable capture cells', span);
								output.push(TCellCapturedAssign(name, scope.cellClass(name), value, span));
							} else if (currentCells.exists(name))
								output.push(TCellAssign(name, currentCells.get(name), value, span));
							else
								output.push(TAssign(scope.resolveId(name), value, span));
						}
					} else {
						var objectName = name.substr(0, dot),
							fieldName = name.substr(dot + 1),
							object = typeExpression(Variable(objectName, span), scope),
							expected:CompilerType;
						switch object.expression {
							case TClassRef(className):
								var staticField = findStaticField(className, fieldName, span);
								value = coerce(value, staticField.type, 'field "$name"', "E1002");
								output.push(TStaticFieldAssign(staticField.owner, fieldName, value, span));
							default:
								expected = fieldType(object.type, fieldName, span);
								value = coerce(value, expected, 'field "$name"', "E1002");
								output.push(TFieldAssign(object, fieldName, value, span));
						}
					}
				case IndexAssignment(array, offset, expression, span):
					var typedArray = typeExpression(array, scope),
						typedIndex = typeExpression(offset, scope),
						value = typeExpression(expression, scope);
					switch typedArray.type {
						case TMap(key, mapValue):
							typedIndex = coerce(typedIndex, key, "map key", "E1002");
							value = coerce(value, mapValue, "map value", "E1002");
							output.push(TMapAssign(typedArray, typedIndex, value, span));
						default:
							if (typedIndex.type != TInt)
								fail("E1014", "Array index must be Int", typedIndex.span);
							var element = arrayElementType(typedArray.type, span);
							if (!sameType(value.type, element))
								fail("E1002", "Array element assignment has the wrong type", span);
							output.push(TIndexAssign(typedArray, typedIndex, value, span));
					}
				case If(condition, thenBranch, elseBranch, span):
					var typedCondition = typeExpression(condition, scope);
					if (!sameType(typedCondition.type, TBool))
						fail("E1004", "If condition must be Bool", span);
					var thenScope = narrowedScope(scope, typedCondition, true),
						elseScope = narrowedScope(scope, typedCondition, false),
						typedThen = typeStatements(thenBranch, thenScope, result),
						typedElse = typeStatements(elseBranch, elseScope, result);
					output.push(TIf(typedCondition, typedThen, typedElse, span));
					if (elseBranch.length == 0 && alwaysReturns(typedThen))
						refineAfterGuard(scope, typedCondition);
				case While(condition, body, span):
					var typedCondition = typeExpression(condition, scope);
					if (!sameType(typedCondition.type, TBool))
						fail("E1004", "While condition must be Bool", span);
					loopDepth++;
					var typedBody = typeStatements(body, new Scope(scope), result);
					loopDepth--;
					output.push(TWhile(typedCondition, typedBody, span));
				case ForIn(name, iterable, body, span):
					var typedIterable = typeExpression(iterable, scope),
						element = switch typedIterable.type {
							case TArray(element): element;
							case TMap(key, value):
								var mapName = RuntimeType.mapName(key, value);
								if (mapName == null)
									fail("E1016", "This map key/value type has no compiler-owned runtime ABI", span);
								typedIterable = new TypedExpression(TCall(RuntimeType.mapNative(key, value, "keys"), [typedIterable]), TArray(key), span);
								key;
							default:
								fail("E1014", "For-in iterable must be an Array or Map", span);
								TInt;
						},
						loopScope = new Scope(scope);
					loopScope.define(name, element, span);
					loopDepth++;
					var typedBody = typeStatements(body, loopScope, result);
					loopDepth--;
					output.push(TForIn(loopScope.resolveId(name), typedIterable, typedBody, span));
				case Switch(expression, cases, defaultBranch, hasDefault, span):
					var typedExpression = typeExpression(expression, scope);
					if (!sameType(typedExpression.type, TInt) && !isEnum(typedExpression.type))
						fail("E1019", "Switch requires an Int or enum value", typedExpression.span);
					var typedCases = [], seenCases:Map<String, Bool> = [];
					for (switchCase in cases) {
						var caseScope = new Scope(scope),
							pattern = typeEnumPattern(switchCase.value, typedExpression.type, caseScope),
							typedValue = pattern == null ? coerce(typeExpression(switchCase.value, scope), typedExpression.type, "switch case",
								"E1019") : pattern.value,
							typedBody = typeStatements(switchCase.statements, caseScope, result),
							constructorIndex = pattern == null ? -1 : pattern.index,
							enumName:Null<String> = pattern == null ? null : pattern.enumName,
							bindings = pattern == null ? [] : pattern.bindings;
						if (pattern == null)
							switch typedValue.expression {
								case TEnumLiteral(name, index):
									enumName = name;
									constructorIndex = index;
								default:
							}
						var caseKey = switch typedValue.expression {
							case TIntLiteral(value): 'int:$value';
							case TEnumLiteral(name, index): 'enum:$name:$index';
							default: null;
						};
						if (caseKey != null) {
							if (seenCases.exists(caseKey))
								fail("E1020", "Duplicate switch case", switchCase.span);
							seenCases.set(caseKey, true);
						}
						typedCases.push({
							value: typedValue,
							statements: typedBody,
							enumName: enumName,
							constructorIndex: constructorIndex,
							bindings: bindings,
							span: switchCase.span
						});
					}
					if (isEnum(typedExpression.type) && !hasDefault) {
						var enumName = switch typedExpression.type {
							case TEnum(name): name;
							default: "";
						};
						var enumDecl = enumDecls.get(enumName), missing = [];
						if (enumDecl != null)
							for (index in 0...enumDecl.cases.length)
								if (!seenCases.exists('enum:$enumName:$index'))
									missing.push(enumDecl.cases[index].name);
						if (missing.length > 0)
							fail("E1021", 'Enum switch is missing cases: ${missing.join(", ")}', span);
					}
					var typedDefault = typeStatements(defaultBranch, new Scope(scope), result);
					output.push(TSwitch(typedExpression, typedCases, typedDefault, hasDefault, span));
				case Expression(expression, span):
					output.push(TExpression(typeExpression(expression, scope), span));
			}
		}
		return output;
	}

	function typeEnumPattern(value:AstExpression, expected:CompilerType, scope:Scope):Null<{
		value:TypedExpression,
		enumName:String,
		index:Int,
		bindings:Array<TypedSwitchBinding>
	}> {
		return switch value {
			case Call(name, arguments, span):
				var info = enumCaseInfo(name);
				if (info == null)
					return null;
				if (!sameType(expected, TEnum(info.enumName)))
					fail("E1019", "Enum switch case has the wrong enum type", span);
				if (arguments.length != info.params.length)
					fail("E1019", 'Enum switch case "$name" expects ${info.params.length} bindings', span);
				var bindings = [];
				for (index in 0...arguments.length) {
					var parameterType = lowerType(info.params[index]);
					switch arguments[index] {
						case Variable(binding, bindingSpan):
							if (binding != "_") {
								scope.define(binding, parameterType, bindingSpan);
								bindings.push({name: scope.resolveId(binding), type: parameterType, index: index});
							}
						default:
							fail("E1019", "Enum switch payloads must bind local names or '_'", span);
					}
				}
				{
					value: new TypedExpression(TEnumLiteral(info.enumName, info.index), TEnum(info.enumName), span),
					enumName: info.enumName,
					index: info.index,
					bindings: bindings
				};
			default: null;
		};
	}

	function typeExpression(expression:AstExpression, scope:Scope):TypedExpression
		return switch expression {
			case IntegerLiteral(value, span): new TypedExpression(TIntLiteral(value), TInt, span);
			case FloatLiteral(value, span): new TypedExpression(TFloatLiteral(value), TFloat, span);
			case StringLiteral(value, span): new TypedExpression(TStringLiteral(value), TString, span);
			case BoolLiteral(value, span): new TypedExpression(TBoolLiteral(value), TBool, span);
			case NullLiteral(span): new TypedExpression(TNullLiteral, TNull, span);
			case Variable(name, span):
				var type = scope.resolve(name);
				if (type != null) new TypedExpression(scope.isCapture(name) ? (scope.isCellCapture(name) ? TCellCaptured(name,
					scope.cellClass(name)) : TCaptured(name)) : (currentCells.exists(name) ? TCellLocal(name,
						currentCells.get(name)) : TLocal(name == "this" ? name : scope.resolveId(name))),
					type, span); else {
					var signature = signatures.get(name);
					if (signature != null)
						new TypedExpression(TFunctionRef(name), functionType(signature), span);
					else if (classDecls.exists(name))
						new TypedExpression(TClassRef(name), TClass(name), span);
					else {
						var ownerSeparator = currentFunctionName.lastIndexOf("."),
							owner = ownerSeparator < 0 ? null : currentFunctionName.substr(0, ownerSeparator),
							staticField = owner == null ? null : findStaticFieldNullable(owner, name);
						if (staticField != null)
							return new TypedExpression(TStaticField(staticField.owner, name), staticField.type, span);
						var dot = name.indexOf(".");
						if (dot <= 0) {
							var thisType = scope.resolve("this"),
								field = thisType == null ? null : findFieldType(thisType, name);
							if (field == null)
								fail("E1005", 'Unknown variable "$name"', span);
							new TypedExpression(TField(new TypedExpression(TLocal("this"), thisType, span), name), field, span);
						} else {
							var parts = name.split("."),
								objectName = parts[0],
								fieldName = parts[1],
								enumDecl = enumDecls.get(objectName);
							if (enumDecl != null && parts.length == 2) {
								var index = -1;
								for (i in 0...enumDecl.cases.length)
									if (enumDecl.cases[i].name == fieldName)
										index = i;
								if (index < 0)
									fail("E1005", 'Unknown enum case "$name"', span);
								if (enumDecl.cases[index].params.length > 0)
									fail("E1008", 'Enum case "$name" requires constructor arguments', span);
								return new TypedExpression(TEnumLiteral(objectName, index), TEnum(objectName), span);
							}
							var object = typeExpression(Variable(objectName, span), scope);
							for (index in 1...parts.length)
								object = typedMember(object, parts[index], span);
							object;
						}
					}
				}
			case Lambda(arguments, body, span):
				var lambdaKey = span.file.path + ":" + span.start,
					cachedLambda = lambdaCache.get(lambdaKey);
				if (cachedLambda != null) cachedLambda else {
					var lambdaArguments:Array<{name:String, type:CompilerType}> = [],
						lambdaScope = new Scope(),
						declared:Map<String, Bool> = [];
					for (argument in arguments) {
						var argumentType = lowerType(argument.type);
						lambdaScope.define(argument.name, argumentType, argument.span);
						lambdaArguments.push({name: lambdaScope.resolveId(argument.name), type: argumentType});
						declared.set(argument.name, true);
					}
					collectDeclaredLocals(body, declared);
					var freeVariables:Map<String, Bool> = [];
					collectVariables(body, freeVariables);
					var captures = [], captureCells:Map<String, String> = [];
					for (name in freeVariables.keys())
						if (!declared.exists(name)) {
							var capturedType = scope.resolve(name);
							if (capturedType != null) {
								var cellClass = currentCells.get(name);
								if (cellClass == null && scope.isCellCapture(name))
									cellClass = scope.cellClass(name);
								if (cellClass == null && currentAssigned.exists(name)) {
									cellClass = '$' + 'cell:' + currentFunctionName + ':' + name;
									currentCells.set(name, cellClass);
									currentCellTypes.set(name, capturedType);
								}
								lambdaScope.defineCapture(name, capturedType, span, cellClass != null, cellClass);
								if (cellClass != null)
									captureCells.set(name, cellClass);
								captures.push(name);
							}
						}
					seedLambdaScope(body, lambdaScope);
					var inferredResult:CompilerType = TVoid;
					for (statement in body)
						switch statement {
							case Return(value, _):
								var typedValue = typeExpression(value, lambdaScope);
								if (inferredResult == TVoid) inferredResult = typedValue.type; else if (!sameType(inferredResult,
									typedValue.type)) fail("E1003", "Lambda return types do not match", span);
							default:
						}
					var typedBodyScope = new Scope();
					for (i in 0...lambdaArguments.length) {
						typedBodyScope.define(arguments[i].name, lambdaArguments[i].type, arguments[i].span);
						lambdaArguments[i] = {name: typedBodyScope.resolveId(arguments[i].name), type: lambdaArguments[i].type};
					}
					for (name in captures)
						typedBodyScope.defineCapture(name, scope.resolve(name), span, captureCells.exists(name), captureCells.get(name));
					var lambdaName = '$' + 'lambda:' + currentFunctionName + ':' + span.start,
						previousLambdaAssigned = currentAssigned,
						previousLambdaCells = currentCells,
						previousLambdaCellTypes = currentCellTypes;
					currentAssigned = [];
					collectAssignedLocals(body, currentAssigned);
					currentCells = [];
					currentCellTypes = [];
					var lambdaDeclared:Map<String, Bool> = [];
					for (argument in arguments)
						lambdaDeclared.set(argument.name, true);
					collectDeclaredLocals(body, lambdaDeclared);
					var lambdaCandidates:Map<String, Bool> = [];
					collectMutableCaptureCandidates(body, lambdaDeclared, lambdaCandidates);
					for (name in lambdaCandidates.keys())
						currentCells.set(name, '$' + 'cell:' + lambdaName + ':' + name);
					var typedBody = typeStatements(body, typedBodyScope, inferredResult);
					var lambdaCells = currentCells.copy(),
						lambdaCellTypes = currentCellTypes.copy();
					for (i in 0...lambdaArguments.length)
						if (lambdaCells.exists(arguments[i].name))
							lambdaArguments[i] = {name: arguments[i].name, type: lambdaArguments[i].type};
					currentAssigned = previousLambdaAssigned;
					currentCells = previousLambdaCells;
					currentCellTypes = previousLambdaCellTypes;
					if (inferredResult != TVoid && !alwaysReturns(typedBody))
						fail("E1006", 'Function $lambdaName does not return on every path', span);
					var environment = captures.length == 0 ? null : '$' + 'lambda-env:' + currentFunctionName + ':' + span.start;
					if (environment != null)
						generatedClasses.push({
							name: environment,
							base: null,
							interfaces: [],
							fields: [
								for (name in captures)
									{
										name: name,
										type: captureCells.exists(name) ? TClass(captureCells.get(name)) : scope.resolve(name),
										initializer: null,
										isStatic: false,
										isFinal: false,
										span: span
									}
							],
							methods: [],
							span: span
						});
					generated.push({
						name: lambdaName,
						owner: environment,
						isStatic: environment == null,
						isConstructor: false,
						arguments: lambdaArguments,
						result: inferredResult,
						statements: typedBody,
						cells: lambdaCells,
						cellCaptures: captureCells.copy(),
						span: span
					});
					for (name in lambdaCells.keys()) {
						var cellType = lambdaCellTypes.get(name);
						if (cellType != null)
							generatedClasses.push({
								name: lambdaCells.get(name),
								base: null,
								interfaces: [],
								fields: [
									{
										name: "value",
										type: cellType,
										initializer: null,
										isStatic: false,
										isFinal: false,
										span: span
									}
								],
								methods: [],
								span: span
							});
					}
					var lambdaResult = new TypedExpression(TLambda(lambdaName, environment, captures),
						TFunction([for (argument in lambdaArguments) argument.type], inferredResult), span);
					lambdaCache.set(lambdaKey, lambdaResult);
					lambdaResult;
				}
			case Member(object, name, span): typeMember(object, name, span, scope);
			case Add(left, right, span): arithmetic(left, right, scope, true, span);
			case Sub(left, right, span): arithmetic(left, right, scope, false, span);
			case Mul(left, right, span): numeric(left, right, scope, 2, span);
			case Div(left, right, span): numeric(left, right, scope, 3, span);
			case Mod(left, right, span): modulo(left, right, scope, span);
			case Negate(value, span):
				var typedValue = typeExpression(value, scope);
				if (!sameType(typedValue.type, TInt) && !sameType(typedValue.type, TFloat))
					fail("E1010", "Numeric negation requires an Int or Float operand", span);
				new TypedExpression(TNegate(typedValue), typedValue.type, span);
			case Less(left, right, span): comparison(left, right, scope, 0, span);
			case LessEqual(left, right, span): comparison(left, right, scope, 1, span);
			case Greater(left, right, span): comparison(right, left, scope, 0, span);
			case GreaterEqual(left, right, span): comparison(right, left, scope, 1, span);
			case Equal(left, right, span): comparison(left, right, scope, 2, span);
			case NotEqual(left, right, span):
				var equality = comparison(left, right, scope, 2, span);
				new TypedExpression(TNot(equality), TBool, span);
			case Not(value, span):
				var typedValue = typeExpression(value, scope);
				if (!sameType(typedValue.type, TBool))
					fail("E1011", "Logical negation requires a Bool operand", span);
				new TypedExpression(TNot(typedValue), TBool, span);
			case And(left, right, span): logical(left, right, scope, true, span);
			case Or(left, right, span): logical(left, right, scope, false, span);
			case New(typeName, arguments, span):
				if (!classDecls.exists(typeName) || interfaceDecls.exists(typeName))
					fail("E1007", 'Unknown class "$typeName"', span);
				var constructor = signatures.get(typeName + ".new"),
					implicitConstructor = constructor == null && [
						for (field in classDecls.get(typeName).fields)
							if (!field.isStatic && field.initializer != null) field
					].length > 0,
					expected = constructor == null ? [] : [for (argument in constructor.arguments) lowerType(argument.type)];
				if (arguments.length != expected.length)
					fail("E1008", 'Constructor "$typeName" expects ${expected.length} arguments, got ${arguments.length}', span);
				var typed = [for (argument in arguments) typeExpression(argument, scope)];
				typed = coerceArguments(typed, expected, typeName + ".new");
				new TypedExpression(TNew(typeName, typed, constructor != null || implicitConstructor), TClass(typeName), span);
			case NewArray(element, length, span):
				var typedLength = typeExpression(length, scope);
				if (typedLength.type != TInt)
					fail("E1014", "Array length must be Int", typedLength.span);
				var loweredElement = lowerType(element);
				new TypedExpression(TNewArray(loweredElement, typedLength), TArray(loweredElement), span);
			case NewMap(key, value, span):
				var loweredKey = lowerType(key),
					loweredValue = lowerType(value);
				if (RuntimeType.mapName(loweredKey, loweredValue) == null)
					fail("E1016", "Only compiler-owned primitive Map<String,T> specializations are supported", span);
				new TypedExpression(TNewMap(loweredKey, loweredValue), TMap(loweredKey, loweredValue), span);
			case Index(array, offset, span):
				var typedArray = typeExpression(array, scope),
					typedIndex = typeExpression(offset, scope);
				switch typedArray.type {
					case TMap(key, value):
						var typedKey = coerce(typedIndex, key, "map key", "E1002");
						new TypedExpression(TMapGet(typedArray, typedKey), value, span);
					default:
						if (typedIndex.type != TInt)
							fail("E1014", "Array index must be Int", typedIndex.span);
						var element = arrayElementType(typedArray.type, span);
						new TypedExpression(TIndex(typedArray, typedIndex), element, span);
				}
			case Call(name, arguments, span):
				var callable = scope.resolve(name);
				if (callable != null) {
					var functionType = switch callable {
						case TFunction(argumentTypes, result): {arguments: argumentTypes, result: result};
						default: null;
					};
					if (functionType == null)
						fail("E1007", 'Cannot call non-function "$name"', span);
					var typed = [for (argument in arguments) typeExpression(argument, scope)];
					if (typed.length != functionType.arguments.length)
						fail("E1008", 'Function value "$name" expects ${functionType.arguments.length} arguments, got ${typed.length}', span);
					typed = coerceArguments(typed, functionType.arguments, name);
					new TypedExpression(TClosureCall(new TypedExpression(TLocal(scope.resolveId(name)), callable, span), typed), functionType.result, span);
				} else {
					var parts = name.split("."),
						receiverName = parts.length < 2 ? null : parts[0],
						receiver = receiverName == null ? null : resolveReceiver(receiverName, span, scope),
						methodName = parts.length < 2 ? null : parts[parts.length - 1];
					if (receiver != null && parts.length > 2)
						for (index in 1...parts.length - 1)
							receiver = typedMember(receiver, parts[index], span);
					var receiverType = receiver == null ? null : receiver.type;
					var enumCase = enumCaseInfo(name);
					if (enumCase != null) {
						var expected = [for (param in enumCase.params) lowerType(param)];
						if (arguments.length != expected.length)
							fail("E1008", 'Enum constructor "$name" expects ${expected.length} arguments, got ${arguments.length}', span);
						var typedArguments = [for (argument in arguments) typeExpression(argument, scope)];
						typedArguments = coerceArguments(typedArguments, expected, name);
						return new TypedExpression(TEnumConstruct(enumCase.enumName, enumCase.index, typedArguments), TEnum(enumCase.enumName), span);
					}
					if (receiverType != null && methodName != null) {
						if (receiverType == TString && methodName == "indexOf") {
							if (arguments.length != 1)
								fail("E1008", 'Function "String.indexOf" expects 1 argument, got ${arguments.length}', span);
							var needle = typeExpression(arguments[0], scope);
							if (!sameType(needle.type, TString))
								fail("E1009", "String.indexOf expects a String needle", needle.span);
							return new TypedExpression(TStringIndexOf(receiver, needle), TInt, span);
						}
						if (receiverType == TString && methodName == "substring") {
							if (arguments.length != 2)
								fail("E1008", 'Function "String.substring" expects 2 arguments, got ${arguments.length}', span);
							var start = typeExpression(arguments[0], scope),
								end = typeExpression(arguments[1], scope);
							if (!sameType(start.type, TInt) || !sameType(end.type, TInt))
								fail("E1009", "String.substring expects Int bounds", span);
							return new TypedExpression(TStringSubstring(receiver, start, end), TString, span);
						}
						if (isMap(receiverType))
							return typeMapMethod(receiver, methodName, arguments, span, scope);
						if (isArray(receiverType))
							return typeArrayMethod(receiver, methodName, arguments, span, scope);
						var className = switch receiverType {
							case TClass(value), TInterface(value): value;
							default: null;
						};
						if (className == null)
							fail("E1007", 'Cannot call method on non-object "$receiverName"', span);
						var methodInfoResult = findMethod(className, methodName);
						if (methodInfoResult == null || methodInfoResult.isStatic)
							fail("E1007", 'Unknown instance method "$className.$methodName"', span);
						var methodKey = methodInfoResult.owner + "." + methodName;
						var method = signatures.get(methodKey),
							expected = [for (argument in method.arguments) lowerType(argument.type)],
							typed = [for (argument in arguments) typeExpression(argument, scope)];
						if (typed.length != expected.length)
							fail("E1008", 'Function "$methodKey" expects ${expected.length} arguments, got ${typed.length}', span);
						typed = coerceArguments(typed, expected, methodKey);
						new TypedExpression(TMethodCall(receiver, methodKey, typed), lowerType(method.result), span);
					} else {
						var signature = signatures.get(name);
						var external = externals.get(name),
							expectedArguments = signature == null ? (external == null ? null : external.arguments) : [for (argument in signature.arguments) lowerType(argument.type)],
							result = signature == null ? (external == null ? null : external.result) : lowerType(signature.result);
						if (expectedArguments == null)
							fail("E1007", 'Unknown function "$name"', span);
						if (arguments.length != expectedArguments.length)
							fail("E1008", 'Function "$name" expects ${expectedArguments.length} arguments, got ${arguments.length}', span);
						var typed = [for (argument in arguments) typeExpression(argument, scope)];
						typed = coerceArguments(typed, expectedArguments, name);
						new TypedExpression(TCall(name, typed), result, span);
					}
				}
			case MethodCall(object, name, arguments, span): typeMethodCall(object, name, arguments, span, scope);
		}

	function typeMember(object:AstExpression, name:String, span:SourceSpan, scope:Scope):TypedExpression {
		return typedMember(typeExpression(object, scope), name, span);
	}

	function seedLambdaScope(statements:Array<AstStatement>, scope:Scope):Void {
		for (statement in statements)
			switch (statement) {
				case VarDeclaration(name, declared, initializer, span):
					if (scope.resolve(name) == null) {
						var value = typeExpression(initializer, scope);
						if (declared != null)
							value = coerce(value, lowerType(declared), 'local "$name"', "E1002");
						scope.define(name, value.type, span);
					}
				case If(_, yes, no, _):
					seedLambdaScope(yes, scope);
					seedLambdaScope(no, scope);
				case While(_, body, _), ForIn(_, _, body, _):
					seedLambdaScope(body, scope);
				case Try(tryBranch, catches, _):
					seedLambdaScope(tryBranch, scope);
					for (catchClause in catches)
						seedLambdaScope(catchClause.statements, scope);
				case Switch(_, cases, defaultBranch, _, _):
					for (switchCase in cases)
						seedLambdaScope(switchCase.statements, scope);
					seedLambdaScope(defaultBranch, scope);
				default:
			}
	}

	function typedMember(typedObject:TypedExpression, name:String, span:SourceSpan):TypedExpression {
		switch typedObject.expression {
			case TClassRef(className):
				var staticField = findStaticField(className, name, span);
				return new TypedExpression(TStaticField(staticField.owner, name), staticField.type, span);
			default:
		}
		if (name == "length" && isArray(typedObject.type))
			return new TypedExpression(TArrayLength(typedObject), TInt, span);
		if (name == "length" && sameType(typedObject.type, TString))
			return new TypedExpression(TStringLength(typedObject), TInt, span);
		return new TypedExpression(TField(typedObject, name), fieldType(typedObject.type, name, span), span);
	}

	function findStaticField(className:String, name:String, span:SourceSpan):{owner:String, type:CompilerType} {
		var result = findStaticFieldNullable(className, name);
		if (result != null)
			return result;
		fail("E1005", 'Unknown static field "$className.$name"', span);
		return {owner: className, type: TVoid};
	}

	function findStaticFieldNullable(className:String, name:String):Null<{owner:String, type:CompilerType}> {
		var classDecl = classDecls.get(className);
		if (classDecl == null)
			return null;
		for (field in classDecl.fields)
			if (field.name == name && field.isStatic)
				return {owner: className, type: lowerType(field.type)};
		return classDecl.base == null ? null : findStaticFieldNullable(classDecl.base, name);
	}

	function typeMethodCall(object:AstExpression, name:String, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope):TypedExpression {
		var receiver = typeExpression(object, scope);
		if (sameType(receiver.type, TString) && name == "indexOf") {
			if (arguments.length != 1)
				fail("E1008", 'Function "String.indexOf" expects 1 argument, got ${arguments.length}', span);
			var needle = typeExpression(arguments[0], scope);
			if (!sameType(needle.type, TString))
				fail("E1009", "String.indexOf expects a String needle", needle.span);
			return new TypedExpression(TStringIndexOf(receiver, needle), TInt, span);
		}
		if (sameType(receiver.type, TString) && name == "substring") {
			if (arguments.length != 2)
				fail("E1008", 'Function "String.substring" expects 2 arguments, got ${arguments.length}', span);
			var start = typeExpression(arguments[0], scope),
				end = typeExpression(arguments[1], scope);
			if (!sameType(start.type, TInt) || !sameType(end.type, TInt))
				fail("E1009", "String.substring expects Int bounds", span);
			return new TypedExpression(TStringSubstring(receiver, start, end), TString, span);
		}
		if (isMap(receiver.type))
			return typeMapMethod(receiver, name, arguments, span, scope);
		if (isArray(receiver.type))
			return typeArrayMethod(receiver, name, arguments, span, scope);
		var className = switch receiver.type {
			case TClass(value), TInterface(value): value;
			default: null;
		};
		if (className == null)
			fail("E1007", 'Cannot call method on non-object "$name"', span);
		var methodInfoResult = findMethod(className, name);
		if (methodInfoResult == null || methodInfoResult.isStatic)
			fail("E1007", 'Unknown instance method "$className.$name"', span);
		var methodKey = methodInfoResult.owner + "." + name,
			method = signatures.get(methodKey),
			expected = [for (argument in method.arguments) lowerType(argument.type)],
			typed = [for (argument in arguments) typeExpression(argument, scope)];
		if (typed.length != expected.length)
			fail("E1008", 'Function "$methodKey" expects ${expected.length} arguments, got ${typed.length}', span);
		typed = coerceArguments(typed, expected, methodKey);
		return new TypedExpression(TMethodCall(receiver, methodKey, typed), lowerType(method.result), span);
	}

	function typeArrayMethod(receiver:TypedExpression, name:String, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope):TypedExpression {
		var element = switch receiver.type {
			case TArray(value): value;
			default: throw "Not an array";
		};
		if (RuntimeType.arrayName(element) == null)
			fail("E1016", "This array element type has no compiler-owned runtime ABI", span);
		if (name == "push") {
			if (arguments.length != 1)
				fail("E1008", "Array.push expects one argument", span);
			if (!isRebindableArrayReceiver(receiver))
				fail("E1016", "Array.push requires a mutable local or field array", span);
			var value = coerce(typeExpression(arguments[0], scope), element, "array element", "E1002");
			return new TypedExpression(TArrayPush(receiver, value), TInt, span);
		}
		if (name == "pop") {
			if (arguments.length != 0)
				fail("E1008", "Array.pop expects no arguments", span);
			return new TypedExpression(TArrayPop(receiver), element, span);
		}
		if (name == "copy") {
			if (arguments.length != 0)
				fail("E1008", "Array.copy expects no arguments", span);
			return new TypedExpression(TCall(RuntimeType.arrayNative(element, "copy"), [receiver]), TArray(element), span);
		}
		if (name == "concat") {
			if (arguments.length != 1)
				fail("E1008", "Array.concat expects one argument", span);
			var other = typeExpression(arguments[0], scope),
				otherElement = arrayElementType(other.type, span);
			if (!sameType(otherElement, element))
				fail("E1002", "Array.concat expects matching element types", span);
			return new TypedExpression(TCall(RuntimeType.arrayNative(element, "concat"), [receiver, other]), TArray(element), span);
		}
		if (name == "slice") {
			if (arguments.length < 1 || arguments.length > 2)
				fail("E1008", "Array.slice expects a start and optional end", span);
			var start = coerce(typeExpression(arguments[0], scope), TInt, "slice start", "E1002"),
				end = arguments.length == 2 ? coerce(typeExpression(arguments[1], scope), TInt, "slice end",
					"E1002") : new TypedExpression(TArrayLength(receiver), TInt, span);
			return new TypedExpression(TCall(RuntimeType.arrayNative(element, "slice"), [receiver, start, end]), TArray(element), span);
		}
		if (name == "indexOf") {
			switch element {
				case TInt, TFloat, TBool, TString:
				default:
					fail("E1016", "Array.indexOf currently supports primitive and String arrays only", span);
			}
			if (arguments.length != 1)
				fail("E1008", "Array.indexOf expects one argument", span);
			var value = coerce(typeExpression(arguments[0], scope), element, "array element", "E1002");
			return new TypedExpression(TCall(RuntimeType.arrayNative(element, "index_of"), [receiver, value]), TInt, span);
		}
		fail("E1007", 'Unknown array method "$name"', span);
		return new TypedExpression(TNullLiteral, TVoid, span);
	}

	function isRebindableArrayReceiver(receiver:TypedExpression):Bool
		return switch receiver.expression {
			case TLocal(_): true;
			case TField(object, name): mutableField(object.type, name);
			default: false;
		};

	function mutableField(type:CompilerType, name:String):Bool
		return switch type {
			case TClass(className):
				var classDecl = classDecls.get(className), found = false;
				if (classDecl != null) {
					for (field in classDecl.fields)
						if (field.name == name && !field.isStatic)
							found = !field.isFinal;
					if (!found && classDecl.base != null)
						found = mutableField(TClass(classDecl.base), name);
				}
				found;
			default: false;
		};

	function typeMapMethod(receiver:TypedExpression, name:String, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope):TypedExpression {
		var mapType = switch receiver.type {
			case TMap(key, value): {key: key, value: value};
			default: throw "Not a map";
		};
		if (RuntimeType.mapName(mapType.key, mapType.value) == null)
			fail("E1016", "This map key/value type has no compiler-owned runtime ABI", span);
		if (name == "set") {
			if (arguments.length != 2)
				fail("E1008", "Map.set expects a key and value", span);
			var key = coerce(typeExpression(arguments[0], scope), mapType.key, "map key", "E1002"),
				value = coerce(typeExpression(arguments[1], scope), mapType.value, "map value", "E1002");
			return new TypedExpression(TCall(RuntimeType.mapNative(mapType.key, mapType.value, "set"), [receiver, key, value]), TVoid, span);
		}
		if (name == "keys") {
			if (arguments.length != 0)
				fail("E1008", "Map.keys expects no arguments", span);
			return new TypedExpression(TCall(RuntimeType.mapNative(mapType.key, mapType.value, "keys"), [receiver]), TArray(mapType.key), span);
		}
		if (name == "values") {
			if (arguments.length != 0)
				fail("E1008", "Map.values expects no arguments", span);
			return new TypedExpression(TCall(RuntimeType.mapNative(mapType.key, mapType.value, "values"), [receiver]), TArray(mapType.value), span);
		}
		if (name == "clear") {
			if (arguments.length != 0)
				fail("E1008", "Map.clear expects no arguments", span);
			return new TypedExpression(TCall(RuntimeType.mapNative(mapType.key, mapType.value, "clear"), [receiver]), TVoid, span);
		}
		if (name == "size") {
			if (arguments.length != 0)
				fail("E1008", "Map.size expects no arguments", span);
			return new TypedExpression(TCall(RuntimeType.mapNative(mapType.key, mapType.value, "size"), [receiver]), TInt, span);
		}
		if (arguments.length != 1)
			fail("E1008", 'Map.$name expects one argument', span);
		var key = coerce(typeExpression(arguments[0], scope), mapType.key, "map key", "E1002");
		return switch name {
			case "exists": new TypedExpression(TCall(RuntimeType.mapNative(mapType.key, mapType.value, "exists"), [receiver, key]), TBool, span);
			case "remove": new TypedExpression(TCall(RuntimeType.mapNative(mapType.key, mapType.value, "remove"), [receiver, key]), TBool, span);
			case "get": new TypedExpression(TMapGet(receiver, key), mapType.value, span);
			default:
				fail("E1007", 'Unknown map method "$name"', span);
				new TypedExpression(TNullLiteral, TVoid, span);
		};
	}

	function narrowedScope(scope:Scope, condition:TypedExpression, truthy:Bool):Scope {
		var result = new Scope(scope), comparison = nullComparison(condition);
		if (comparison != null) {
			var nonNull = truthy == comparison.nonNullWhenTrue;
			result.refine(comparison.name, nonNull ? comparison.nonNullType : TNull);
		}
		return result;
	}

	function refineAfterGuard(scope:Scope, condition:TypedExpression):Void {
		var comparison = nullComparison(condition);
		if (comparison != null)
			scope.refine(comparison.name, comparison.nonNullWhenTrue ? TNull : comparison.nonNullType);
	}

	function nullComparison(condition:TypedExpression):Null<{name:String, nonNullType:CompilerType, nonNullWhenTrue:Bool}> {
		return switch condition.expression {
			case TEqual(left, right): var local = nullableLocal(left),
					other = isNullValue(right) ? true : false; if (local == null) {
					local = nullableLocal(right);
					other = isNullValue(left);
				} local == null || !other ? null : {name: local.name, nonNullType: local.nonNullType, nonNullWhenTrue: false};
			case TNot(value):
				var comparison = nullComparison(value);
				comparison == null ? null : {
					name: comparison.name,
					nonNullType: comparison.nonNullType,
					nonNullWhenTrue: !comparison.nonNullWhenTrue
				};
			default: null;
		};
	}

	function nullableLocal(expression:TypedExpression):Null<{name:String, nonNullType:CompilerType}> {
		return switch expression.expression {
			case TLocal(name), TCellLocal(name, _): switch expression.type {
					case TNullable(element): {name: name, nonNullType: element};
					default: null;
				};
			default: null;
		};
	}

	static function isNullValue(expression:TypedExpression):Bool
		return switch expression.expression {
			case TNullLiteral: true;
			case TNullableWrap(value): isNullValue(value);
			default: false;
		};

	function functionType(fn:AstFunction):CompilerType
		return TFunction([for (argument in fn.arguments) lowerType(argument.type)], lowerType(fn.result));

	static function collectAssignedLocals(statements:Array<AstStatement>, names:Map<String, Bool>):Void {
		for (statement in statements)
			switch (statement) {
				case Assignment(name, _, _):
					if (name.indexOf(".") < 0)
						names.set(name, true);
				case Increment(name, _, _):
					names.set(name, true);
				case If(_, yes, no, _):
					collectAssignedLocals(yes, names);
					collectAssignedLocals(no, names);
				case While(_, body, _):
					collectAssignedLocals(body, names);
				case ForIn(name, _, body, _):
					names.set(name, true);
					collectAssignedLocals(body, names);
				case Switch(_, cases, defaultBranch, _, _):
					for (switchCase in cases)
						collectAssignedLocals(switchCase.statements, names);
					collectAssignedLocals(defaultBranch, names);
				case Try(tryBranch, catches, _):
					collectAssignedLocals(tryBranch, names);
					for (catchClause in catches)
						collectAssignedLocals(catchClause.statements, names);
				default:
			}
	}

	static function collectDeclaredLocals(statements:Array<AstStatement>, names:Map<String, Bool>):Void {
		for (statement in statements)
			switch statement {
				case VarDeclaration(name, _, _, _):
					names.set(name, true);
				case If(_, yes, no, _):
					collectDeclaredLocals(yes, names);
					collectDeclaredLocals(no, names);
				case While(_, body, _):
					collectDeclaredLocals(body, names);
				case ForIn(name, _, body, _):
					names.set(name, true);
					collectDeclaredLocals(body, names);
				case Switch(_, cases, defaultBranch, _, _):
					for (switchCase in cases)
						collectDeclaredLocals(switchCase.statements, names);
					collectDeclaredLocals(defaultBranch, names);
				case Try(tryBranch, catches, _):
					collectDeclaredLocals(tryBranch, names);
					for (catchClause in catches)
						collectDeclaredLocals(catchClause.statements, names);
				case Break(_), Continue(_):
				case Increment(_, _, _):
				default:
			}
	}

	static function collectVariables(statements:Array<AstStatement>, names:Map<String, Bool>):Void {
		for (statement in statements)
			switch statement {
				case VarDeclaration(_, _, expression, _), Assignment(_, expression, _), Return(expression, _), Throw(expression, _), Expression(expression, _):
					collectExpressionVariables(expression, names);
				case IndexAssignment(array, offset, expression, _):
					collectExpressionVariables(array, names);
					collectExpressionVariables(offset, names);
					collectExpressionVariables(expression, names);
				case ReturnVoid(_):
				case If(condition, yes, no, _):
					collectExpressionVariables(condition, names);
					collectVariables(yes, names);
					collectVariables(no, names);
				case While(condition, body, _):
					collectExpressionVariables(condition, names);
					collectVariables(body, names);
				case ForIn(_, iterable, body, _):
					collectExpressionVariables(iterable, names);
					collectVariables(body, names);
				case Switch(expression, cases, defaultBranch, _, _):
					collectExpressionVariables(expression, names);
					for (switchCase in cases) {
						collectExpressionVariables(switchCase.value, names);
						collectVariables(switchCase.statements, names);
					}
					collectVariables(defaultBranch, names);
				case Try(tryBranch, catches, _):
					collectVariables(tryBranch, names);
					for (catchClause in catches)
						collectVariables(catchClause.statements, names);
				case Break(_), Continue(_):
				case Increment(name, _, _):
					names.set(name, true);
			}
	}

	static function collectMutableCaptureCandidates(statements:Array<AstStatement>, outerDeclared:Map<String, Bool>, result:Map<String, Bool>):Void {
		for (statement in statements)
			switch (statement) {
				case VarDeclaration(_, _, expression, _), Assignment(_, expression, _), Return(expression, _), Throw(expression, _), Expression(expression, _):
					collectMutableCaptureExpression(expression, outerDeclared, result);
				case IndexAssignment(array, offset, expression, _):
					collectMutableCaptureExpression(array, outerDeclared, result);
					collectMutableCaptureExpression(offset, outerDeclared, result);
					collectMutableCaptureExpression(expression, outerDeclared, result);
				case If(condition, yes, no, _):
					collectMutableCaptureExpression(condition, outerDeclared, result);
					collectMutableCaptureCandidates(yes, outerDeclared, result);
					collectMutableCaptureCandidates(no, outerDeclared, result);
				case While(condition, body, _):
					collectMutableCaptureExpression(condition, outerDeclared, result);
					collectMutableCaptureCandidates(body, outerDeclared, result);
				case ForIn(_, iterable, body, _):
					collectMutableCaptureExpression(iterable, outerDeclared, result);
					collectMutableCaptureCandidates(body, outerDeclared, result);
				case Switch(expression, cases, defaultBranch, _, _):
					collectMutableCaptureExpression(expression, outerDeclared, result);
					for (switchCase in cases) {
						collectMutableCaptureExpression(switchCase.value, outerDeclared, result);
						collectMutableCaptureCandidates(switchCase.statements, outerDeclared, result);
					}
					collectMutableCaptureCandidates(defaultBranch, outerDeclared, result);
				case Try(tryBranch, catches, _):
					collectMutableCaptureCandidates(tryBranch, outerDeclared, result);
					for (catchClause in catches)
						collectMutableCaptureCandidates(catchClause.statements, outerDeclared, result);
				case ReturnVoid(_), Break(_), Continue(_), Increment(_, _, _):
			}
	}

	/**
		Locals mutated in a protected region and observed by its handler need stable
		storage: an exception can bypass SSA edge moves at any throwing instruction.
	**/
	static function collectExceptionCellCandidates(statements:Array<AstStatement>, declared:Map<String, Bool>, result:Map<String, Bool>):Void {
		for (statement in statements)
			switch statement {
				case Try(tryBranch, catches, _):
					var assigned:Map<String, Bool> = [],
						observed:Map<String, Bool> = [];
					collectAssignedLocals(tryBranch, assigned);
					for (catchClause in catches)
						collectVariables(catchClause.statements, observed);
					for (name in observed.keys())
						if (assigned.exists(name) && declared.exists(name))
							result.set(name, true);
					collectExceptionCellCandidates(tryBranch, declared, result);
					for (catchClause in catches)
						collectExceptionCellCandidates(catchClause.statements, declared, result);
				case If(_, yes, no, _):
					collectExceptionCellCandidates(yes, declared, result);
					collectExceptionCellCandidates(no, declared, result);
				case While(_, body, _), ForIn(_, _, body, _):
					collectExceptionCellCandidates(body, declared, result);
				case Switch(_, cases, defaultBranch, _, _):
					for (switchCase in cases)
						collectExceptionCellCandidates(switchCase.statements, declared, result);
					collectExceptionCellCandidates(defaultBranch, declared, result);
				default:
			}
	}

	static function collectMutableCaptureExpression(expression:AstExpression, outerDeclared:Map<String, Bool>, result:Map<String, Bool>):Void
		switch (expression) {
			case Lambda(arguments, body, _):
				var declared:Map<String, Bool> = [];
				for (argument in arguments)
					declared.set(argument.name, true);
				collectDeclaredLocals(body, declared);
				var names:Map<String, Bool> = [],
					assigned:Map<String, Bool> = [];
				collectVariables(body, names);
				collectAssignedLocals(body, assigned);
				for (name in assigned.keys())
					names.set(name, true);
				for (name in names.keys())
					if (!declared.exists(name) && outerDeclared.exists(name))
						result.set(name, true);
				collectMutableCaptureCandidates(body, outerDeclared, result);
			case Member(object, _, _):
				collectMutableCaptureExpression(object, outerDeclared, result);
			case MethodCall(object, _, arguments, _):
				collectMutableCaptureExpression(object, outerDeclared, result);
				for (argument in arguments)
					collectMutableCaptureExpression(argument, outerDeclared, result);
			case Call(_, arguments, _):
				for (argument in arguments)
					collectMutableCaptureExpression(argument, outerDeclared, result);
			case Add(left, right, _), Sub(left, right, _), Mul(left, right, _), Div(left, right, _), Mod(left, right, _), Less(left, right, _),
				LessEqual(left, right, _), Greater(left, right, _), GreaterEqual(left, right, _), Equal(left, right, _), NotEqual(left, right, _),
				And(left, right, _), Or(left, right, _):
				collectMutableCaptureExpression(left, outerDeclared, result);
				collectMutableCaptureExpression(right, outerDeclared, result);
			case Negate(value, _), Not(value, _):
				collectMutableCaptureExpression(value, outerDeclared, result);
			case New(_, arguments, _):
				for (argument in arguments)
					collectMutableCaptureExpression(argument, outerDeclared, result);
			case NewArray(_, length, _):
				collectMutableCaptureExpression(length, outerDeclared, result);
			case Index(array, offset, _):
				collectMutableCaptureExpression(array, outerDeclared, result);
				collectMutableCaptureExpression(offset, outerDeclared, result);
			case Variable(_, _), IntegerLiteral(_, _), FloatLiteral(_, _), StringLiteral(_, _), BoolLiteral(_, _), NullLiteral(_), NewMap(_, _, _):
		}

	static function collectExpressionVariables(expression:AstExpression, names:Map<String, Bool>):Void
		switch expression {
			case Variable(name, _):
				names.set(name, true);
			case Member(object, _, _):
				collectExpressionVariables(object, names);
			case MethodCall(object, _, arguments, _):
				collectExpressionVariables(object, names);
				for (argument in arguments)
					collectExpressionVariables(argument, names);
			case Call(name, arguments, _):
				var separator = name.indexOf(".");
				if (separator > 0)
					names.set(name.substr(0, separator), true);
				for (argument in arguments)
					collectExpressionVariables(argument, names);
			case Add(left, right, _), Sub(left, right, _), Mul(left, right, _), Div(left, right, _), Mod(left, right, _), Less(left, right, _),
				LessEqual(left, right, _), Greater(left, right, _), GreaterEqual(left, right, _), Equal(left, right, _), NotEqual(left, right, _):
				collectExpressionVariables(left, names);
				collectExpressionVariables(right, names);
			case Negate(value, _):
				collectExpressionVariables(value, names);
			case Not(value, _):
				collectExpressionVariables(value, names);
			case And(left, right, _), Or(left, right, _):
				collectExpressionVariables(left, names);
				collectExpressionVariables(right, names);
			case New(_, arguments, _):
				for (argument in arguments)
					collectExpressionVariables(argument, names);
			case NewArray(_, length, _):
				collectExpressionVariables(length, names);
			case NewMap(_, _, _):
			case Index(array, offset, _):
				collectExpressionVariables(array, names);
				collectExpressionVariables(offset, names);
			case Lambda(_, body, _):
				collectVariables(body, names);
			case IntegerLiteral(_, _):
				return;
			case FloatLiteral(_, _):
				return;
			case StringLiteral(_, _):
				return;
			case BoolLiteral(_, _), NullLiteral(_):
				return;
		}

	function coerceArguments(arguments:Array<TypedExpression>, expected:Array<CompilerType>, name:String):Array<TypedExpression> {
		var output = [];
		for (i in 0...arguments.length)
			output.push(coerce(arguments[i], expected[i], 'argument ${i + 1} to "$name"'));
		return output;
	}

	function coerce(value:TypedExpression, expected:CompilerType, context:String, code:String = "E1009"):TypedExpression {
		return switch relations.conversion(value.type, expected) {
			case Identity: value;
			case ToDynamic:
				new TypedExpression(TToDynamic(value), expected, value.span);
			case ToInterface(name):
				new TypedExpression(TToInterface(value, name), expected, value.span);
			case WrapNullable:
				new TypedExpression(TNullableWrap(value), expected, value.span);
			case Incompatible:
				fail(code, 'Type mismatch for $context', value.span);
				value;
		};
	}

	function isAssignable(actual:CompilerType, expected:CompilerType):Bool {
		return relations.isAssignable(actual, expected);
	}

	function findMethod(className:String, name:String):Null<{owner:String, isStatic:Bool, isConstructor:Bool}> {
		var info = methodInfo.get(className + "." + name);
		if (info != null)
			return info;
		var classDecl = classDecls.get(className);
		if (classDecl != null)
			return classDecl.base == null ? null : findMethod(classDecl.base, name);
		var interfaceDecl = interfaceDecls.get(className);
		if (interfaceDecl != null)
			for (base in interfaceDecl.bases) {
				var inherited = findMethod(base, name);
				if (inherited != null)
					return inherited;
			}
		return null;
	}

	function enumCaseInfo(name:String):Null<{enumName:String, index:Int, params:Array<AstType>}> {
		var dot = name.indexOf(".");
		if (dot <= 0)
			return null;
		var enumName = name.substr(0, dot),
			caseName = name.substr(dot + 1),
			declaration = enumDecls.get(enumName);
		if (declaration == null)
			return null;
		for (index in 0...declaration.cases.length)
			if (declaration.cases[index].name == caseName)
				return {enumName: enumName, index: index, params: declaration.cases[index].params};
		return null;
	}

	function fieldType(type:CompilerType, name:String, span:SourceSpan):CompilerType {
		switch type {
			case TClass(className):
				var classDecl = classDecls.get(className);
				if (classDecl != null) {
					for (field in classDecl.fields)
						if (field.name == name && !field.isStatic)
							return lowerType(field.type);
					if (classDecl.base != null)
						return fieldType(TClass(classDecl.base), name, span);
				}
				fail("E1005", 'Unknown field "$className.$name"', span);
			default:
				fail("E1005", 'Field "$name" requires an object', span);
		}
		return TVoid;
	}

	function resolveReceiver(name:String, span:SourceSpan, scope:Scope):Null<TypedExpression> {
		if (scope.resolve(name) != null)
			return typeExpression(Variable(name, span), scope);
		var thisType = scope.resolve("this");
		if (thisType != null && findFieldType(thisType, name) != null)
			return typeExpression(Variable(name, span), scope);
		var ownerSeparator = currentFunctionName.lastIndexOf("."),
			owner = ownerSeparator < 0 ? null : currentFunctionName.substr(0, ownerSeparator),
			staticField = owner == null ? null : findStaticFieldNullable(owner, name);
		if (staticField != null)
			return new TypedExpression(TStaticField(staticField.owner, name), staticField.type, span);
		return null;
	}

	function findFieldType(type:CompilerType, name:String):Null<CompilerType>
		return switch type {
			case TClass(className):
				var classDecl = classDecls.get(className),
					found:Null<CompilerType> = null;
				if (classDecl != null) {
					for (field in classDecl.fields)
						if (field.name == name && !field.isStatic)
							found = lowerType(field.type);
					if (found == null && classDecl.base != null)
						found = findFieldType(TClass(classDecl.base), name);
				}
				found;
			default: null;
		};

	function arithmetic(a, b, scope, add, span):TypedExpression {
		var left = typeExpression(a, scope), right = typeExpression(b, scope);
		if (add && sameType(left.type, TString) && sameType(right.type, TString))
			return new TypedExpression(TAdd(left, right), TString, span);
		if (!sameType(left.type, right.type) || (!sameType(left.type, TInt) && !sameType(left.type, TFloat)))
			fail("E1010", "Arithmetic requires matching Int or Float operands", span);
		return new TypedExpression(add ? TAdd(left, right) : TSub(left, right), left.type, span);
	}

	function logical(a, b, scope, and, span):TypedExpression {
		var left = typeExpression(a, scope),
			rightScope = narrowedScope(scope, left, and),
			right = typeExpression(b, rightScope);
		if (!sameType(left.type, TBool) || !sameType(right.type, TBool))
			fail("E1011", "Logical operators require Bool operands", span);
		return new TypedExpression(and ? TAnd(left, right) : TOr(left, right), TBool, span);
	}

	function numeric(a, b, scope, operation, span):TypedExpression {
		var left = typeExpression(a, scope), right = typeExpression(b, scope);
		if (!sameType(left.type, right.type) || (!sameType(left.type, TInt) && !sameType(left.type, TFloat)))
			fail("E1010", "Arithmetic requires matching Int or Float operands", span);
		return new TypedExpression(operation == 2 ? TMul(left, right) : TDiv(left, right), left.type, span);
	}

	function modulo(a, b, scope, span):TypedExpression {
		var left = typeExpression(a, scope), right = typeExpression(b, scope);
		if (!sameType(left.type, TInt) || !sameType(right.type, TInt))
			fail("E1010", "Modulo requires matching Int operands", span);
		return new TypedExpression(TMod(left, right), TInt, span);
	}

	function comparison(a, b, scope, operation, span):TypedExpression {
		var left = typeExpression(a, scope), right = typeExpression(b, scope);
		if (operation == 2) {
			if (sameType(left.type, TNull) && isNullable(right.type))
				left = coerce(left, right.type, "null comparison");
			else if (sameType(right.type, TNull) && isNullable(left.type))
				right = coerce(right, left.type, "null comparison");
		}
		if (operation == 2 && sameType(left.type, TString) && sameType(right.type, TString))
			return new TypedExpression(TEqual(left, right), TBool, span);
		if (operation == 2 && sameType(left.type, TBool) && sameType(right.type, TBool))
			return new TypedExpression(TEqual(left, right), TBool, span);
		if (operation == 2 && (sameType(left.type, TNull) || sameType(right.type, TNull)))
			switch [left.type, right.type] {
				case [TNull, TNullable(_)], [TNullable(_), TNull], [TNullable(_), TNullable(_)]:
					return new TypedExpression(TEqual(left, right), TBool, span);
				default:
			}
		if (operation == 2 && sameType(left.type, right.type))
			switch left.type {
				case TEnum(_), TNullable(_):
					return new TypedExpression(TEqual(left, right), TBool, span);
				default:
			}
		if (!sameType(left.type, right.type) || (left.type != TInt && left.type != TFloat))
			fail("E1011", "Comparison requires matching Int or Float operands", span);
		return new TypedExpression(switch operation {
			case 0: TLess(left, right);
			case 1: TLessEqual(left, right);
			default: TEqual(left, right);
		}, TBool, span);
	}

	function alwaysReturns(statements:Array<TypedStatement>):Bool {
		for (statement in statements)
			switch statement {
				case TReturn(_, _), TReturnVoid(_), TThrow(_, _):
					return true;
				case TIf(_, yes, no, _):
					if (no.length > 0 && alwaysReturns(yes) && alwaysReturns(no))
						return true;
				case TTry(tryBranch, catches, _):
					if (alwaysReturns(tryBranch)
						&& catches.length > 0
						&& [for (catchClause in catches) alwaysReturns(catchClause.statements)].indexOf(false) < 0)
						return true;
				case TSwitch(expression, cases, defaultBranch, hasDefault, _):
					if ((hasDefault ? alwaysReturns(defaultBranch) : exhaustiveEnum(expression.type, cases))
						&& [for (switchCase in cases) alwaysReturns(switchCase.statements)].indexOf(false) < 0)
						return true;
				default:
			}
		return false;
	}

	function exhaustiveEnum(type:CompilerType, cases:Array<TypedSwitchCase>):Bool {
		var enumName = switch type {
			case TEnum(name): name;
			default: return false;
		};
		var enumDecl = enumDecls.get(enumName);
		if (enumDecl == null)
			return false;
		var seen:Map<Int, Bool> = [];
		for (switchCase in cases)
			if (switchCase.constructorIndex >= 0)
				seen.set(switchCase.constructorIndex, true);
		for (index in 0...enumDecl.cases.length)
			if (!seen.exists(index))
				return false;
		return true;
	}

	function lowerType(type:AstType):CompilerType
		return declarations.resolve(type);

	function arrayElementType(type:CompilerType, span:SourceSpan):CompilerType
		return switch type {
			case TArray(element): element;
			default:
				fail("E1015", "Indexing requires an Array value", span);
				TVoid;
		};

	function arrayLengthType(type:CompilerType):CompilerType
		return isArray(type) ? TInt : TVoid;

	static function isArray(type:CompilerType):Bool
		return switch type {
			case TArray(_): true;
			default: false;
		};

	static function isMap(type:CompilerType):Bool
		return switch type {
			case TMap(_, _): true;
			default: false;
		};

	static function isEnum(type:CompilerType):Bool
		return switch type {
			case TEnum(_): true;
			default: false;
		};

	static function isNullable(type:CompilerType):Bool
		return switch type {
			case TNullable(_): true;
			default: false;
		};

	static function isReference(type:CompilerType):Bool
		return switch type {
			case TString, TDynamic, TClass(_), TInterface(_), TArray(_), TFunction(_), TMap(_, _): true;
			default: false;
		};

	static function statementSpan(statement:AstStatement):SourceSpan
		return switch statement {
			case VarDeclaration(_, _, _, span), Assignment(_, _, span), IndexAssignment(_, _, _, span), Return(_, span), ReturnVoid(span), Throw(_, span),
				Try(_, _, span), If(_, _, _, span), While(_, _, span), ForIn(_, _, _, span), Break(span), Continue(span), Switch(_, _, _, _, span),
				Increment(_, _, span), Expression(_, span): span;
		}

	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));

	static function sameType(left:CompilerType, right:CompilerType):Bool
		return TypeRelations.equals(left, right);
}
