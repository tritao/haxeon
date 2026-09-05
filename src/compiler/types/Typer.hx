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
import compiler.types.TypedAst.TypedExpressionKind;
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
	var enumAbstractDecls:Map<String, compiler.Ast.AstEnumAbstract> = [];
	var declarations:DeclarationIndex;
	var relations:TypeRelations;
	final generated:Array<TypedFunction> = [];
	final generatedCells:Array<compiler.types.TypedAst.TypedCell> = [];
	final generatedEnvironments:Array<compiler.types.TypedAst.TypedCaptureEnvironment> = [];
	final lambdaCache:Map<String, TypedExpression> = [];
	var context:BodyContext = new BodyContext("");
	final anonymousTypes:Map<String, Array<compiler.types.Type.AnonymousField>> = [];
	final genericSpecializations:Map<String, String> = [];

	public static function type(program:AstProgram):TypedProgram
		return new Typer(null).typeProgram(program, null, true);

	/** Type a reusable module without requiring an executable main function. */
	public static function typeLibrary(program:AstProgram):TypedProgram
		return new Typer(null).typeProgram(program, null, false);

	public static function typeSelected(program:AstProgram, selected:Map<String, Bool>,
			?externals:Map<String, {arguments:Array<CompilerType>, result:CompilerType}>):TypedProgram
		return new Typer(externals).typeProgram(program, selected, true);

	function new(externals:Null<Map<String, {arguments:Array<CompilerType>, result:CompilerType}>>)
		this.externals = externals == null ? [] : externals;

	function typeProgram(program:AstProgram, selected:Null<Map<String, Bool>>, requireMain:Bool):TypedProgram {
		program = SignatureInference.inferProgram(program);
		declarations = new DeclarationIndex(program);
		relations = new TypeRelations(declarations);
		enumDecls = declarations.enums;
		enumAbstractDecls = declarations.enumAbstracts;
		for (decl in program.enumAbstracts) {
			var underlying = lowerType(decl.underlying);
			for (value in decl.values)
				coerce(typeExpression(value.value, new Scope(), underlying), underlying, 'enum abstract value "${decl.name}.${value.name}"', "E1002");
		}
		interfaceDecls = declarations.interfaces;
		classDecls = declarations.classes;
		for (alias in program.aliases)
			registerAnonymousTypes(lowerType(alias.type));
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
			if (main == null)
				main = signatures.get("Main.main");
			if (main == null || main.arguments.length != 0 || (lowerType(main.result) != TInt && lowerType(main.result) != TVoid))
				throw "Program must define main():Int or static Main.main():Void";
		}
		var typedEnums = [
			for (enumDecl in program.enums)
				{
					name: enumDecl.name,
					cases: [
						for (caseDecl in enumDecl.cases)
							{
								name: caseDecl.name,
								params: [
									for (param in caseDecl.params)
										param.optional ? TNullable(lowerType(param.type)) : lowerType(param.type)
								],
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
							{name: method.name, arguments: [for (argument in method.arguments) argumentType(argument)], result: lowerType(method.result)}
					]
				}
			], typedClasses = [for (classDecl in program.classes) typeClass(classDecl, classDecls, selected)], typedFunctions:Array<TypedFunction> = [];
		for (fn in program.functions)
			if (!isGeneric(fn) && (selected == null || selected.exists(fn.name)))
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
			classes: typedClasses,
			functions: typedFunctions,
			cells: generatedCells,
			captureEnvironments: generatedEnvironments,
			anonymousTypes: orderedAnonymousTypes()
		};
	}

	function typeClass(classDecl:AstClass, classes:Map<String, AstClass>, selected:Null<Map<String, Bool>>):TypedClass {
		var fields:Array<TypedField> = [], fieldNames:Map<String, Bool> = [];
		for (field in classDecl.fields) {
			if (fieldNames.exists(field.name))
				fail("E1000", 'Duplicate field "${classDecl.name}.${field.name}"', field.span);
			var type = lowerType(FieldInference.parsedType(field));
			if (type == TVoid)
				fail("E1002", 'Field "${classDecl.name}.${field.name}" cannot have type Void', field.span);
			var initializer:Null<TypedExpression> = null;
			if (field.initializer != null) {
				var previousContext = context;
				context = new BodyContext(classDecl.name + ".__init");
				var scope = new Scope();
				if (!field.isStatic)
					scope.define("this", TClass(classDecl.name), field.span);
				initializer = coerce(typeExpression(field.initializer, scope), type,
					(field.isStatic ? 'static field "${classDecl.name}.${field.name}"' : 'field "${classDecl.name}.${field.name}"'), "E1002");
				context = previousContext;
			}
			fieldNames.set(field.name, true);
			fields.push({
				name: field.name,
				type: type,
				initializer: initializer,
				readAccess: field.readAccess,
				writeAccess: field.writeAccess,
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
			if (isGeneric(method))
				continue;
			var qualified = classDecl.name + "." + method.name,
				typeBody = selected == null || selected.exists(qualified),
				typedMethod = typeBody ? typeFunction(method, classDecl.name, method.isStatic) : methodSignature(method, classDecl.name);
			if (method.name == "new") {
				hasConstructor = true;
				if (typeBody && instanceInitializers.length > 0)
					typedMethod = prependInstanceInitializers(typedMethod, classDecl.name, instanceInitializers);
			}
			typedMethods.push(typedMethod);
		}
		if (!hasConstructor && instanceInitializers.length > 0 && (selected == null || selected.exists(classDecl.name + ".new")))
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

	function methodSignature(method:AstFunction, owner:String):TypedFunction
		return {
			name: owner + "." + method.name,
			owner: owner,
			isStatic: method.isStatic,
			isConstructor: method.name == "new",
			arguments: [
				for (argument in method.arguments)
					{
						name: argument.name,
						type: lowerType(argument.type)
					}
			],
			result: lowerType(method.result),
			statements: [],
			cells: [],
			cellCaptures: [],
			span: method.span
		};

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

	function typeFunction(fn:AstFunction, ?owner:String, isStatic:Bool = false, ?substitutions:Map<String, CompilerType>,
			?specializedName:String):TypedFunction {
		var previousContext = context;
		var functionName = specializedName == null ? (owner == null ? fn.name : owner + "." + fn.name) : specializedName;
		context = new BodyContext(functionName, substitutions);
		collectAssignedLocals(fn.statements, context.assigned);
		var declared:Map<String, Bool> = [];
		for (argument in fn.arguments)
			declared.set(argument.name, true);
		collectDeclaredLocals(fn.statements, declared);
		var mutableCandidates:Map<String, Bool> = [];
		collectMutableCaptureCandidates(fn.statements, declared, mutableCandidates);
		var exceptionCandidates:Map<String, Bool> = [];
		collectExceptionCellCandidates(fn.statements, declared, exceptionCandidates);
		for (name in mutableCandidates.keys()) {
			context.cells.set(name, '$' + 'cell:' + context.name + ':' + name);
			context.cellKinds.set(name, MutableCapture);
		}
		for (name in exceptionCandidates.keys()) {
			context.cells.set(name, '$' + 'cell:' + context.name + ':' + name);
			if (!context.cellKinds.exists(name))
				context.cellKinds.set(name, ExceptionEdge);
		}
		var scope = new Scope();
		var isConstructor = owner != null && fn.name == "new";
		if (owner != null && !isStatic)
			scope.define("this", TClass(owner), fn.span);
		var arguments = [];
		for (argument in fn.arguments) {
			var type = argumentType(argument);
			scope.define(argument.name, type, argument.span);
			if (context.cells.exists(argument.name))
				context.cellTypes.set(argument.name, type);
			arguments.push({name: context.cells.exists(argument.name) ? argument.name : scope.resolveId(argument.name), type: type});
		}
		var result = lowerType(fn.result);
		context.resultType = result;
		var statements = typeStatements(fn.statements, scope, result);
		if (result != TVoid && !alwaysReturns(statements))
			fail("E1006", 'Function ${fn.name} does not return on every path', fn.span);
		var resultFunction:TypedFunction = {
			name: functionName,
			genericOrigin: specializedName == null ? null : (owner == null ? fn.name : owner + "." + fn.name),
			typeArguments: specializedName == null || fn.typeParameters == null ? null : [
				for (parameter in fn.typeParameters)
					context.typeSubstitutions.get(parameter)
			],
			owner: owner,
			isStatic: isStatic,
			isConstructor: isConstructor,
			arguments: arguments,
			result: result,
			statements: statements,
			cells: context.cells.copy(),
			cellCaptures: [],
			span: fn.span
		};
		for (name in context.cells.keys()) {
			var cellType = context.cellTypes.get(name);
			if (cellType != null)
				generatedCells.push({name: context.cells.get(name), valueType: cellType, kind: context.cellKinds.get(name)});
		}
		context = previousContext;
		return resultFunction;
	}

	function typeStatements(statements:Array<AstStatement>, scope:Scope, result:CompilerType):Array<TypedStatement> {
		var output = [];
		for (statementIndex in 0...statements.length) {
			var statement = statements[statementIndex];
			if (alwaysReturns(output))
				fail("E1012", "Unreachable statement", statementSpan(statement));
			switch statement {
				case UninitializedDeclaration(name, declared, span):
					var declaredType = lowerType(declared);
					if (context.cells.exists(name))
						fail("E1023", 'Captured local "$name" must be initialized at its declaration', span);
					scope.define(name, declaredType, span, false);
					output.push(TDeclare(scope.resolveId(name), declaredType, span));
				case VarDeclaration(name, declared, initializer, span):
					var declaredType = declared == null ? expectedLocalInitializerType(name, initializer, statements, statementIndex + 1,
						result) : lowerType(declared),
						predeclared = declaredType != null && switch initializer {
							case Lambda(_, _, _): true;
							default: false;
						};
					if (predeclared)
						scope.define(name, declaredType, span);
					var value = typeExpression(initializer, scope, declaredType);
					if (declared != null) {
						value = coerce(value, declaredType, 'local "$name"', "E1002");
					} else if (sameType(value.type, TNull)) {
						fail("E1002", 'Null requires an explicit nullable type for local "$name"', span);
					}
					if (!predeclared)
						scope.define(name, value.type, span);
					if (context.cells.exists(name))
						context.cellTypes.set(name, value.type);
					output.push(TVar(context.cells.exists(name) ? name : scope.resolveId(name), value, span));
				case Return(expression, span):
					var value = typeExpression(expression, scope, result);
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
					var typedCatches:Array<TypedCatch> = [],
						catchScopes:Array<Scope> = [],
						tryScope = new Scope(scope);
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
						catchScopes.push(catchScope);
						catchScope.define(catchClause.name, loweredCatchType, catchClause.span);
						typedCatches.push({
							name: catchScope.resolveId(catchClause.name),
							type: loweredCatchType,
							statements: typeStatements(catchClause.statements, catchScope, result),
							span: catchClause.span
						});
					}
					var typedTry = typeStatements(tryBranch, tryScope, result);
					output.push(TTry(typedTry, typedCatches, span));
					var continuing = [];
					if (!alwaysExits(typedTry))
						continuing.push(tryScope);
					for (i in 0...typedCatches.length)
						if (!alwaysExits(typedCatches[i].statements))
							continuing.push(catchScopes[i]);
					scope.mergeAssignmentsFrom(continuing);
				case Break(span):
					if (context.loopDepth == 0)
						fail("E1017", "break is only valid inside a loop", span);
					if (!context.loopEarlyExits[context.loopEarlyExits.length - 1])
						fail("E1017", "break in do-while is not supported by the current CFG backend", span);
					output.push(TBreak(span));
				case Continue(span):
					if (context.loopDepth == 0)
						fail("E1017", "continue is only valid inside a loop", span);
					if (!context.loopEarlyExits[context.loopEarlyExits.length - 1])
						fail("E1017", "continue in do-while is not supported by the current CFG backend", span);
					output.push(TContinue(span));
				case Increment(name, delta, span):
					var current = scope.resolve(name);
					if (current != null && !scope.isAssigned(name))
						fail("E1023", 'Local "$name" may be used before assignment', span);
					if (current == null) {
						var dot = name.indexOf("."),
							ownerSeparator = context.name.lastIndexOf("."),
							owner = dot < 0 ? (ownerSeparator < 0 ? null : context.name.substr(0, ownerSeparator)) : name.substr(0, dot),
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
					} else if (context.cells.exists(name))
						output.push(TCellIncrement(name, context.cells.get(name), current, delta, span));
					else
						output.push(TIncrement(scope.resolveId(name), delta, span));
				case Assignment(name, expression, span):
					var dot = name.indexOf("."),
						value = typeExpression(expression, scope);
					if (dot < 0) {
						var expected = scope.resolveDeclared(name);
						if (expected == null) {
							var thisType = scope.resolve("this"),
								instanceField = thisType == null ? null : findFieldType(thisType, name);
							if (instanceField != null) {
								value = coerce(value, instanceField, 'field "$name"', "E1002");
								output.push(TFieldAssign(new TypedExpression(TLocal("this"), thisType, span), name, value, span));
							} else {
								var ownerSeparator = context.name.lastIndexOf("."),
									owner = ownerSeparator < 0 ? null : context.name.substr(0, ownerSeparator),
									staticField = owner == null ? null : findStaticFieldNullable(owner, name);
								if (staticField == null)
									fail("E1005", 'Unknown variable "$name"', span);
								value = coerce(value, staticField.type, 'field "$name"', "E1002");
								output.push(TStaticFieldAssign(staticField.owner, name, value, span));
							}
						} else {
							value = coerce(value, expected, 'local "$name"', "E1002");
							if (scope.isCapture(name)) {
								if (!scope.isCellCapture(name))
									fail("E1013", 'Captured variable "$name" requires mutable capture cells', span);
								output.push(TCellCapturedAssign(name, scope.cellClass(name), value, span));
							} else if (context.cells.exists(name))
								output.push(TCellAssign(name, context.cells.get(name), value, span));
							else
								output.push(TAssign(scope.resolveId(name), value, span));
							scope.markAssigned(name);
							scope.refine(name, value.type);
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
				case FieldAssignment(objectExpression, fieldName, expression, span):
					var object = typeExpression(objectExpression, scope),
						value = typeExpression(expression, scope);
					switch object.expression {
						case TClassRef(className):
							var staticField = findStaticField(className, fieldName, span);
							value = coerce(value, staticField.type, 'field "$fieldName"', "E1002");
							output.push(TStaticFieldAssign(staticField.owner, fieldName, value, span));
						default:
							var expected = fieldType(object.type, fieldName, span);
							value = coerce(value, expected, 'field "$fieldName"', "E1002");
							output.push(TFieldAssign(object, fieldName, value, span));
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
					var continuing = [];
					if (!alwaysExits(typedThen))
						continuing.push(thenScope);
					if (elseBranch.length == 0)
						continuing.push(scope);
					else if (!alwaysExits(typedElse))
						continuing.push(elseScope);
					scope.mergeAssignmentsFrom(continuing);
					if (elseBranch.length == 0 && alwaysReturns(typedThen))
						refineAfterGuard(scope, typedCondition);
				case While(condition, body, span):
					var typedCondition = typeExpression(condition, scope);
					if (!sameType(typedCondition.type, TBool))
						fail("E1004", "While condition must be Bool", span);
					context.loopDepth++;
					context.loopEarlyExits.push(true);
					var typedBody = typeStatements(body, new Scope(scope), result);
					context.loopEarlyExits.pop();
					context.loopDepth--;
					output.push(TWhile(typedCondition, typedBody, span));
				case DoWhile(body, condition, span):
					var bodyScope = new Scope(scope);
					context.loopDepth++;
					context.loopEarlyExits.push(false);
					var typedBody = typeStatements(body, bodyScope, result);
					context.loopEarlyExits.pop();
					context.loopDepth--;
					var typedCondition = typeExpression(condition, bodyScope);
					if (!sameType(typedCondition.type, TBool))
						fail("E1004", "Do-while condition must be Bool", span);
					output.push(TDoWhile(typedBody, typedCondition, span));
					scope.mergeAssignmentsFrom([bodyScope]);
				case ForIn(name, valueName, iterable, body, span):
					var typedIterable = typeExpression(iterable, scope),
						originalIterable = typedIterable,
						element = switch typedIterable.type {
							case TArray(element): element;
							case TRange: TInt;
							case TMap(key, value):
								var mapName = RuntimeType.mapName(key, value);
								if (mapName == null)
									fail("E1016", "This map key/value type has no compiler-owned runtime ABI", span);
								if (valueName == null)
									typedIterable = new TypedExpression(TCollectionCall(typedIterable, "keys", []), TArray(key), span);
								key;
							default:
								fail("E1014", "For-in iterable must be an Array or Map", span);
								TInt;
						},
						loopScope = new Scope(scope);
					loopScope.define(name, element, span);
					if (valueName != null)
						switch originalIterable.type {
							case TMap(_, value): loopScope.define(valueName, value, span);
							default: fail("E1014", "Key/value for-in requires a Map", span);
						}
					context.loopDepth++;
					context.loopEarlyExits.push(true);
					var typedBody = typeStatements(body, loopScope, result);
					context.loopEarlyExits.pop();
					context.loopDepth--;
					output.push(TForIn(loopScope.resolveId(name), valueName == null ? null : loopScope.resolveId(valueName),
						valueName == null ? typedIterable : originalIterable, typedBody, span));
				case Switch(expression, cases, defaultBranch, hasDefault, span):
					var typedExpression = typeExpression(expression, scope);
					if (!sameType(typedExpression.type, TInt) && !isEnum(typedExpression.type))
						fail("E1019", "Switch requires an Int or enum value", typedExpression.span);
					var typedCases = [],
						caseScopes = [],
						seenCases:Map<String, Bool> = [];
					for (switchCase in cases) {
						var caseScope = new Scope(scope),
							pattern = typeEnumPattern(switchCase.value, typedExpression.type, caseScope),
							typedValue = pattern == null ? coerce(typeExpression(switchCase.value, scope), typedExpression.type, "switch case",
								"E1019") : pattern.value,
							typedGuard = switchCase.guard == null ? null : coerce(typeExpression(switchCase.guard, caseScope), TBool, "switch guard", "E1003"),
							typedBody = typeStatements(switchCase.statements, caseScope, result),
							constructorIndex = pattern == null ? -1 : pattern.index,
							enumName:Null<String> = pattern == null ? null : pattern.enumName,
							bindings = pattern == null ? [] : pattern.bindings;
						caseScopes.push(caseScope);
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
						if (caseKey != null && typedGuard == null) {
							if (seenCases.exists(caseKey))
								fail("E1020", "Duplicate switch case", switchCase.span);
							seenCases.set(caseKey, true);
						}
						typedCases.push({
							value: typedValue,
							guard: typedGuard,
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
					var defaultScope = new Scope(scope),
						typedDefault = typeStatements(defaultBranch, defaultScope, result);
					output.push(TSwitch(typedExpression, typedCases, typedDefault, hasDefault, span));
					var continuing = [];
					for (i in 0...typedCases.length)
						if (!alwaysExits(typedCases[i].statements))
							continuing.push(caseScopes[i]);
					if (hasDefault) {
						if (!alwaysExits(typedDefault))
							continuing.push(defaultScope);
					} else if (!exhaustiveEnum(typedExpression.type, typedCases))
						continuing.push(scope);
					scope.mergeAssignmentsFrom(continuing);
				case Expression(expression, span):
					output.push(TExpression(typeExpression(expression, scope), span));
			}
		}
		return output;
	}

	function expectedLocalInitializerType(name:String, initializer:AstExpression, statements:Array<AstStatement>, start:Int,
			result:CompilerType):Null<CompilerType> {
		var canUseResult = switch initializer {
			case ArrayLiteral(values, _): values.length == 0 && switch result {
					case TArray(_): true;
					default: false;
				};
			case MapLiteral(entries, _): entries.length == 0 && switch result {
					case TMap(_, _): true;
					default: false;
				};
			default: false;
		};
		if (!canUseResult)
			return null;
		for (index in start...statements.length)
			switch statements[index] {
				case Return(Variable(returned, _), _) if (returned == name):
					return result;
				case VarDeclaration(shadowed, _, _, _) if (shadowed == name):
					return null;
				case UninitializedDeclaration(shadowed, _, _) if (shadowed == name):
					return null;
				default:
			}
		return null;
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
				var required = requiredEnumParameters(info.params);
				if (arguments.length < required || arguments.length > info.params.length)
					fail("E1019", 'Enum switch case "$name" expects $required to ${info.params.length} bindings', span);
				var bindings = [];
				for (index in 0...arguments.length) {
					var parameter = info.params[index],
						parameterType = parameter.optional ? TNullable(lowerType(parameter.type)) : lowerType(parameter.type);
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

	function typeExpression(expression:AstExpression, scope:Scope, ?expectedType:CompilerType):TypedExpression
		return switch expression {
			case IntegerLiteral(value, span): new TypedExpression(TIntLiteral(value), TInt, span);
			case FloatLiteral(value, span): new TypedExpression(TFloatLiteral(value), TFloat, span);
			case StringLiteral(value, span): new TypedExpression(TStringLiteral(value), TString, span);
			case BoolLiteral(value, span): new TypedExpression(TBoolLiteral(value), TBool, span);
			case NullLiteral(span): new TypedExpression(TNullLiteral, TNull, span);
			case Unreachable(span): new TypedExpression(TUnreachable, TNever, span);
			case Variable(name, span):
				var type = scope.resolve(name);
				if (type != null) {
					if (!scope.isAssigned(name))
						fail("E1023", 'Local "$name" may be used before assignment', span);
					new TypedExpression(scope.isCapture(name) ? (scope.isCellCapture(name) ? TCellCaptured(name,
						scope.cellClass(name)) : TCaptured(name)) : (context.cells.exists(name) ? TCellLocal(name,
							context.cells.get(name)) : TLocal(name == "this" ? name : scope.resolveId(name))),
						type, span);
				} else {
					var signature = signatures.get(name);
					if (signature != null)
						new TypedExpression(TFunctionRef(name), functionType(signature), span);
					else if (classDecls.exists(name) || enumAbstractDecls.exists(name) || PlatformAbi.isType(name))
						new TypedExpression(TClassRef(name), TClass(name), span);
					else {
						var ownerSeparator = context.name.lastIndexOf("."),
							owner = ownerSeparator < 0 ? null : context.name.substr(0, ownerSeparator),
							staticField = owner == null ? null : findStaticFieldNullable(owner, name);
						if (staticField != null)
							return new TypedExpression(TStaticField(staticField.owner, name), staticField.type, span);
						var dot = name.indexOf(".");
						if (dot <= 0) {
							var expectedEnum = switch expectedType {
								case TEnum(enumName): enumDecls.get(enumName);
								default: null;
							};
							if (expectedEnum != null)
								for (index in 0...expectedEnum.cases.length) {
									var enumCase = expectedEnum.cases[index];
									if (enumCase.name == name && enumCase.params.length == 0)
										return new TypedExpression(TEnumLiteral(expectedEnum.name, index), TEnum(expectedEnum.name), span);
								}
							var thisType = scope.resolve("this"),
								field = thisType == null ? null : findFieldType(thisType, name);
							if (field == null)
								fail("E1005", 'Unknown variable "$name"', span);
							new TypedExpression(TField(new TypedExpression(TLocal("this"), thisType, span), name), field, span);
						} else {
							var parts = name.split("."),
								objectName = parts[0],
								fieldName = parts[1],
								lastDot = name.lastIndexOf("."),
								enumName = name.substr(0, lastDot),
								enumCaseName = name.substr(lastDot + 1),
								enumDecl = enumDecls.get(enumName);
							if (enumDecl != null) {
								var index = -1;
								for (i in 0...enumDecl.cases.length)
									if (enumDecl.cases[i].name == enumCaseName)
										index = i;
								if (index < 0)
									fail("E1005", 'Unknown enum case "$name"', span);
								if (enumDecl.cases[index].params.length > 0)
									fail("E1008", 'Enum case "$name" requires constructor arguments', span);
								return new TypedExpression(TEnumLiteral(enumName, index), TEnum(enumName), span);
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
					var expectedFunction = switch expectedType {
						case TFunction(expectedArguments, expectedResult): {arguments: expectedArguments, result: expectedResult};
						default: null;
					};
					if (expectedFunction != null && expectedFunction.arguments.length != arguments.length)
						fail("E1008", 'Lambda expects ${expectedFunction.arguments.length} arguments, got ${arguments.length}', span);
					var lambdaArguments:Array<{name:String, type:CompilerType}> = [],
						lambdaScope = new Scope(),
						declared:Map<String, Bool> = [];
					for (i in 0...arguments.length) {
						var argument = arguments[i];
						var argumentType = argument.type == InferredType ? (expectedFunction == null ? null : expectedFunction.arguments[i]) : lowerType(argument.type);
						if (argumentType == null)
							fail("E1003", 'Cannot infer lambda parameter "${argument.name}" without a function context', argument.span);
						if (expectedFunction != null && !TypeRelations.equals(argumentType, expectedFunction.arguments[i]))
							fail("E1003", "Lambda argument type does not match its context", argument.span);
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
								var cellClass = context.cells.get(name);
								if (cellClass == null && scope.isCellCapture(name))
									cellClass = scope.cellClass(name);
								if (cellClass == null && context.assigned.exists(name)) {
									cellClass = '$' + 'cell:' + context.name + ':' + name;
									context.cells.set(name, cellClass);
									context.cellTypes.set(name, capturedType);
									context.cellKinds.set(name, MutableCapture);
								}
								lambdaScope.defineCapture(name, capturedType, span, cellClass != null, cellClass);
								if (cellClass != null)
									captureCells.set(name, cellClass);
								captures.push(name);
							}
						}
					seedLambdaScope(body, lambdaScope);
					var inferredResult:CompilerType = expectedFunction == null ? TVoid : expectedFunction.result;
					if (expectedFunction == null)
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
					var lambdaName = '$' + 'lambda:' + context.name + ':' + span.start,
						previousContext = context;
					context = new BodyContext(lambdaName, previousContext.typeSubstitutions);
					context.resultType = inferredResult;
					collectAssignedLocals(body, context.assigned);
					var lambdaDeclared:Map<String, Bool> = [];
					for (argument in arguments)
						lambdaDeclared.set(argument.name, true);
					collectDeclaredLocals(body, lambdaDeclared);
					var lambdaCandidates:Map<String, Bool> = [];
					collectMutableCaptureCandidates(body, lambdaDeclared, lambdaCandidates);
					for (name in lambdaCandidates.keys()) {
						context.cells.set(name, '$' + 'cell:' + lambdaName + ':' + name);
						context.cellKinds.set(name, MutableCapture);
					}
					var typedBody = typeStatements(body, typedBodyScope, inferredResult);
					var lambdaCells = context.cells.copy(),
						lambdaCellTypes = context.cellTypes.copy(),
						lambdaCellKinds = context.cellKinds.copy();
					for (i in 0...lambdaArguments.length)
						if (lambdaCells.exists(arguments[i].name))
							lambdaArguments[i] = {name: arguments[i].name, type: lambdaArguments[i].type};
					context = previousContext;
					if (inferredResult != TVoid && !alwaysReturns(typedBody))
						fail("E1006", 'Function $lambdaName does not return on every path', span);
					var environment = captures.length == 0 ? null : '$' + 'lambda-env:' + context.name + ':' + span.start;
					if (environment != null)
						generatedEnvironments.push({
							name: environment,
							fields: [
								for (name in captures)
									{
										name: name,
										type: captureCells.exists(name) ? TClass(captureCells.get(name)) : scope.resolve(name)
									}
							]
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
							generatedCells.push({name: lambdaCells.get(name), valueType: cellType, kind: lambdaCellKinds.get(name)});
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
			case BitAnd(left, right, span): bitwise(left, right, scope, 0, span);
			case BitXor(left, right, span): bitwise(left, right, scope, 1, span);
			case BitOr(left, right, span): bitwise(left, right, scope, 2, span);
			case ShiftLeft(left, right, span): bitwise(left, right, scope, 3, span);
			case ShiftRight(left, right, span): bitwise(left, right, scope, 4, span);
			case UnsignedShiftRight(left, right, span): bitwise(left, right, scope, 5, span);
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
			case Conditional(condition, whenTrue, whenFalse, span):
				var typedCondition = typeExpression(condition, scope, TBool);
				if (!sameType(typedCondition.type, TBool))
					fail("E1011", "Conditional expression requires a Bool condition", span);
				var typedTrue = typeExpression(whenTrue, narrowedScope(scope, typedCondition, true), expectedType),
					typedFalse = typeExpression(whenFalse, narrowedScope(scope, typedCondition, false), expectedType),
					resultType = expectedType == null ? (typedTrue.type == TNever ? typedFalse.type : typedTrue.type) : expectedType;
				if (expectedType == null
					&& typedTrue.type != TNever
					&& typedFalse.type != TNever
					&& !sameType(typedTrue.type, typedFalse.type))
					fail("E1003", "Conditional branches must have matching types", span);
				typedTrue = coerce(typedTrue, resultType, "conditional branch", "E1003");
				typedFalse = coerce(typedFalse, resultType, "conditional branch", "E1003");
				new TypedExpression(TConditional(typedCondition, typedTrue, typedFalse), resultType, span);
			case BlockExpression(statements, result, span):
				var blockScope = new Scope(scope),
					typedStatements = typeStatements(statements, blockScope, context.resultType),
					typedResult = typeExpression(result, blockScope, expectedType);
				new TypedExpression(TBlockExpression(typedStatements, typedResult), typedResult.type, span);
			case ThrowExpression(value, span):
				new TypedExpression(TThrowExpression(typeExpression(value, scope)), TNever, span);
			case Cast(value, target, span):
				var targetType = target == null ? expectedType : lowerType(target);
				if (targetType == null)
					fail("E1003", "Untyped cast requires an expected type", span);
				new TypedExpression(TCast(typeExpression(value, scope)), targetType, span);
			case PostfixIncrement(target, delta, span):
				var typedTarget = typeExpression(target, scope);
				if (!sameType(typedTarget.type, TInt) && !sameType(typedTarget.type, TFloat))
					fail("E1018", "Postfix increment requires a numeric target", span);
				var operation = switch typedTarget.expression {
					case TLocal(name): TPostfixLocal(name, delta);
					case TCellLocal(name, cellClass): TPostfixCellLocal(name, cellClass, delta);
					case TCellCaptured(name, cellClass): TPostfixCellCaptured(name, cellClass, delta);
					case TStaticField(owner, name): TPostfixStaticField(owner, name, delta);
					case TField(object, name): TPostfixField(object, name, delta);
					case TIndex(array, index): TPostfixIndex(array, index, delta);
					default:
						fail("E1018", "Postfix increment target is not assignable", span);
						TPostfixLocal("", delta);
				};
				new TypedExpression(operation, typedTarget.type, span);
			case SwitchExpression(expression, cases, defaultExpression, span):
				var typedSubject = typeExpression(expression, scope);
				if (!sameType(typedSubject.type, TInt) && !sameType(typedSubject.type, TString) && !isEnum(typedSubject.type))
					fail("E1019", "Switch requires an Int, String, or enum value", typedSubject.span);
				var typedCases = [],
					seenCases:Map<String, Bool> = [],
					resultType = expectedType;
				for (switchCase in cases) {
					var caseScope = new Scope(scope),
						pattern = typeEnumPattern(switchCase.value, typedSubject.type, caseScope),
						typedValue = pattern == null ? coerce(typeExpression(switchCase.value, scope), typedSubject.type, "switch case",
							"E1019") : pattern.value,
						typedGuard = switchCase.guard == null ? null : coerce(typeExpression(switchCase.guard, caseScope), TBool, "switch guard", "E1003"),
						typedResult = typeExpression(switchCase.result, caseScope, resultType),
						enumName:Null<String> = pattern == null ? null : pattern.enumName,
						constructorIndex = pattern == null ? -1 : pattern.index;
					if (resultType == null && typedResult.type != TNever)
						resultType = typedResult.type;
					if (resultType != null)
						typedResult = coerce(typedResult, resultType, "switch branch", "E1003");
					if (pattern == null)
						switch typedValue.expression {
							case TEnumLiteral(name, index):
								enumName = name;
								constructorIndex = index;
							default:
						}
					var caseKey = switch typedValue.expression {
						case TIntLiteral(value): 'int:$value';
						case TStringLiteral(value): 'string:$value';
						case TEnumLiteral(name, index): 'enum:$name:$index';
						default: null;
					};
					if (caseKey != null && typedGuard == null) {
						if (seenCases.exists(caseKey))
							fail("E1020", "Duplicate switch case", switchCase.span);
						seenCases.set(caseKey, true);
					}
					typedCases.push({
						value: typedValue,
						guard: typedGuard,
						result: typedResult,
						enumName: enumName,
						constructorIndex: constructorIndex,
						bindings: pattern == null ? [] : pattern.bindings
					});
				}
				var typedDefault = defaultExpression == null ? null : typeExpression(defaultExpression, scope, resultType);
				if (typedDefault != null) {
					if (resultType == null && typedDefault.type != TNever)
						resultType = typedDefault.type;
					if (resultType != null)
						typedDefault = coerce(typedDefault, resultType, "switch branch", "E1003");
				}
				if (resultType == null)
					fail("E1003", "Switch expression has no result branches", span);
				typedCases = [
					for (switchCase in typedCases)
						{
							value: switchCase.value,
							guard: switchCase.guard,
							result: coerce(switchCase.result, resultType, "switch branch", "E1003"),
							enumName: switchCase.enumName,
							constructorIndex: switchCase.constructorIndex,
							bindings: switchCase.bindings
						}
				];
				if (typedDefault != null)
					typedDefault = coerce(typedDefault, resultType, "switch branch", "E1003");
				if (typedDefault == null && !isEnum(typedSubject.type))
					fail("E1021", "Switch expression requires a default branch", span);
				if (isEnum(typedSubject.type) && typedDefault == null) {
					var enumName = switch typedSubject.type {
						case TEnum(name): name;
						default: "";
					}, enumDecl = enumDecls.get(enumName), missing = [];
					if (enumDecl != null)
						for (index in 0...enumDecl.cases.length)
							if (!seenCases.exists('enum:$enumName:$index'))
								missing.push(enumDecl.cases[index].name);
					if (missing.length > 0)
						fail("E1021", 'Enum switch is missing cases: ${missing.join(", ")}', span);
				}
				new TypedExpression(TSwitchExpression(typedSubject, typedCases, typedDefault), resultType, span);
			case ObjectLiteral(fields, span):
				var expectedFields = switch expectedType {
					case TAnonymous(_, values): values;
					default: null;
				};
				var seen:Map<String, Bool> = [], typedFields = [];
				for (field in fields) {
					if (seen.exists(field.name))
						fail("E1001", 'Duplicate object field "${field.name}"', field.span);
					seen.set(field.name, true);
					var expectedField = anonymousField(expectedFields, field.name);
					if (expectedFields != null && expectedField == null)
						fail("E1002", 'Unexpected object field "${field.name}"', field.span);
					var value = typeExpression(field.value, scope, expectedField == null ? null : expectedField.type);
					if (expectedField != null)
						value = coerce(value, expectedField.type, 'object field "${field.name}"', "E1002");
					typedFields.push({name: field.name, value: value});
				}
				if (expectedFields != null)
					for (field in expectedFields)
						if (!field.optional && !seen.exists(field.name))
							fail("E1002", 'Missing object field "${field.name}"', span);
				typedFields.sort(function(left, right) return Reflect.compare(left.name, right.name));
				var resultType = expectedType;
				if (resultType == null) {
					var inferred = [
						for (field in typedFields)
							{name: field.name, type: field.value.type, optional: false}
					];
					resultType = TAnonymous(anonymousTypeName(inferred), inferred);
				}
				var typeName = switch resultType {
					case TAnonymous(name, _): name;
					default: "";
				};
				registerAnonymousTypes(resultType);
				new TypedExpression(TObjectLiteral(typeName, typedFields), resultType, span);
			case ArrayLiteral(values, span):
				var expectedElement = switch expectedType {
					case TArray(element): element;
					default: null;
				};
				if (values.length == 0 && expectedElement == null)
					fail("E1003", "Empty array literal requires an expected element type", span);
				var typedValues = [], elementType = expectedElement;
				for (value in values) {
					var typedValue = typeExpression(value, scope, elementType);
					if (elementType == null)
						elementType = typedValue.type;
					typedValues.push(coerce(typedValue, elementType, "array element", "E1003"));
				}
				new TypedExpression(TArrayLiteral(typedValues), TArray(elementType), span);
			case MapLiteral(entries, span):
				var expected = switch expectedType {
					case TMap(key, value): {key: key, value: value};
					default: null;
				}, keyType = expected == null ? null : expected.key, valueType = expected == null ? null : expected.value, typedEntries = [];
				for (entry in entries) {
					var key = typeExpression(entry.key, scope, keyType),
						value = typeExpression(entry.value, scope, valueType);
					if (keyType == null)
						keyType = key.type;
					if (valueType == null)
						valueType = value.type;
					typedEntries.push({
						key: coerce(key, keyType, "map key", "E1003"),
						value: coerce(value, valueType, "map value", "E1003")
					});
				}
				if (RuntimeType.mapName(keyType, valueType) == null)
					fail("E1016", "This map key/value type has no compiler-owned runtime ABI", span);
				new TypedExpression(TMapLiteral(typedEntries), TMap(keyType, valueType), span);
			case ArrayComprehension(keyName, valueName, iterable, condition, value, span):
				var typedIterable = typeExpression(iterable, scope),
					originalIterable = typedIterable,
					loopScope = new Scope(scope),
					keyType:CompilerType;
				switch typedIterable.type {
					case TArray(element):
						if (valueName != null)
							fail("E1014", "Key/value array comprehension requires a Map", span);
						keyType = element;
					case TRange:
						if (valueName != null)
							fail("E1014", "Key/value array comprehension requires a Map", span);
						keyType = TInt;
					case TMap(key, mapValue):
						if (RuntimeType.mapName(key, mapValue) == null)
							fail("E1016", "This map key/value type has no compiler-owned runtime ABI", span);
						keyType = key;
						if (valueName == null) typedIterable = new TypedExpression(TCollectionCall(typedIterable, "keys", []), TArray(key), span);
					default:
						fail("E1014", "Array comprehension iterable must be an Array or Map", span);
						keyType = TInt;
				}
				loopScope.define(keyName, keyType, span);
				if (valueName != null)
					switch originalIterable.type {
						case TMap(_, mapValue): loopScope.define(valueName, mapValue, span);
						default:
					}
				var typedCondition = condition == null ? null : typeExpression(condition, loopScope, TBool);
				if (typedCondition != null && typedCondition.type != TBool)
					fail("E1004", "Array comprehension condition must be Bool", span);
				var expectedElement = switch expectedType {
					case TArray(element): element;
					default: null;
				}, typedValue = typeExpression(value, loopScope, expectedElement), elementType = expectedElement == null ? typedValue.type : expectedElement;
				typedValue = coerce(typedValue, elementType, "array comprehension value", "E1003");
				new TypedExpression(TArrayComprehension(loopScope.resolveId(keyName), valueName == null ? null : loopScope.resolveId(valueName),
					valueName == null ? typedIterable : originalIterable, typedCondition, typedValue),
					TArray(elementType), span);
			case MapComprehension(keyName, valueName, iterable, condition, key, value, span):
				var typedIterable = typeExpression(iterable, scope),
					originalIterable = typedIterable,
					loopScope = new Scope(scope),
					itemType:CompilerType;
				switch typedIterable.type {
					case TArray(element):
						if (valueName != null)
							fail("E1014", "Key/value map comprehension requires a Map", span);
						itemType = element;
					case TRange:
						if (valueName != null)
							fail("E1014", "Key/value map comprehension requires a Map", span);
						itemType = TInt;
					case TMap(mapKey, mapValue):
						if (RuntimeType.mapName(mapKey, mapValue) == null)
							fail("E1016", "This map key/value type has no compiler-owned runtime ABI", span);
						itemType = mapKey;
						if (valueName == null) typedIterable = new TypedExpression(TCollectionCall(typedIterable, "keys", []), TArray(mapKey), span);
					default:
						fail("E1014", "Map comprehension iterable must be an Array or Map", span);
						itemType = TInt;
				}
				loopScope.define(keyName, itemType, span);
				if (valueName != null)
					switch originalIterable.type {
						case TMap(_, mapValue): loopScope.define(valueName, mapValue, span);
						default:
					}
				var typedCondition = condition == null ? null : typeExpression(condition, loopScope, TBool);
				if (typedCondition != null && typedCondition.type != TBool)
					fail("E1004", "Map comprehension condition must be Bool", span);
				var expected = switch expectedType {
					case TMap(expectedKey, expectedValue): {key: expectedKey, value: expectedValue};
					default: null;
				}, typedKey = typeExpression(key, loopScope,
					expected == null ? null : expected.key), typedValue = typeExpression(value, loopScope,
						expected == null ? null : expected.value), resultKey = expected == null ? typedKey.type : expected.key, resultValue = expected == null ? typedValue.type : expected.value;
				typedKey = coerce(typedKey, resultKey, "map comprehension key", "E1003");
				typedValue = coerce(typedValue, resultValue, "map comprehension value", "E1003");
				if (RuntimeType.mapName(resultKey, resultValue) == null)
					fail("E1016", "This map key/value type has no compiler-owned runtime ABI", span);
				new TypedExpression(TMapComprehension(loopScope.resolveId(keyName), valueName == null ? null : loopScope.resolveId(valueName),
					valueName == null ? typedIterable : originalIterable, typedCondition, typedKey, typedValue),
					TMap(resultKey, resultValue), span);
			case Range(start, end, span):
				var typedStart = typeExpression(start, scope, TInt),
					typedEnd = typeExpression(end, scope, TInt);
				if (typedStart.type != TInt || typedEnd.type != TInt)
					fail("E1014", "Range bounds must be Int values", span);
				new TypedExpression(TRange(typedStart, typedEnd), TRange, span);
			case New(typeName, arguments, span):
				if ((!classDecls.exists(typeName) && !PlatformAbi.isType(typeName)) || interfaceDecls.exists(typeName))
					fail("E1007", 'Unknown class "$typeName"', span);
				var constructor = signatures.get(typeName + ".new"),
					implicitConstructor = constructor == null && classDecls.exists(typeName) && [
						for (field in classDecls.get(typeName).fields)
							if (!field.isStatic && field.initializer != null) field
					].length > 0,
					expected = constructor == null ? [] : [for (argument in constructor.arguments) argumentType(argument)];
				if (constructor == null && arguments.length != 0)
					fail("E1008", 'Constructor "$typeName" expects 0 arguments, got ${arguments.length}', span);
				var typed = constructor == null ? typeCallArguments(arguments, expected, scope,
					typeName + ".new") : typeDeclaredCallArguments(arguments, constructor.arguments, scope, typeName + ".new", span);
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
				if (name == "super")
					return typeSuperCall(arguments, span, scope);
				if (name == "String.fromCharCode") {
					if (arguments.length != 1)
						fail("E1008", 'Function "String.fromCharCode" expects 1 argument, got ${arguments.length}', span);
					var code = typeExpression(arguments[0], scope, TInt);
					if (!sameType(code.type, TInt))
						fail("E1009", "String.fromCharCode expects an Int code", code.span);
					return new TypedExpression(TStringFromCharCode(code), TString, span);
				}
				var callable = scope.resolve(name);
				if (callable != null) {
					var functionType = switch callable {
						case TFunction(argumentTypes, result): {arguments: argumentTypes, result: result};
						default: null;
					};
					if (functionType == null)
						fail("E1007", 'Cannot call non-function "$name"', span);
					if (arguments.length != functionType.arguments.length)
						fail("E1008", 'Function value "$name" expects ${functionType.arguments.length} arguments, got ${arguments.length}', span);
					var typed = [
						for (i in 0...arguments.length)
							typeExpression(arguments[i], scope, functionType.arguments[i])
					];
					typed = coerceArguments(typed, functionType.arguments, name);
					new TypedExpression(TClosureCall(new TypedExpression(TLocal(scope.resolveId(name)), callable, span), typed), functionType.result, span);
				} else {
					if (name.indexOf(".") < 0) {
						var ownerSeparator = context.name.lastIndexOf("."),
							owner = ownerSeparator < 0 ? null : context.name.substr(0, ownerSeparator),
							implicitMethod = owner == null ? null : findMethod(owner, name);
						if (implicitMethod != null) {
							var methodKey = implicitMethod.owner + "." + name,
								method = signatures.get(methodKey),
								typed = typeDeclaredCallArguments(arguments, method.arguments, scope, methodKey, span);
							if (implicitMethod.isStatic)
								return new TypedExpression(TCall(methodKey, typed), lowerType(method.result), span);
							var thisType = scope.resolve("this");
							if (thisType == null)
								fail("E1007", 'Instance method "$methodKey" requires an object', span);
							var receiver = new TypedExpression(TLocal("this"), thisType, span);
							return new TypedExpression(TMethodCall(receiver, methodKey, typed), lowerType(method.result), span);
						}
					}
					var parts = name.split("."),
						receiverName = parts.length < 2 || signatures.exists(name) ? null : parts[0],
						receiver = receiverName == null ? null : resolveReceiver(receiverName, span, scope),
						methodName = parts.length < 2 ? null : parts[parts.length - 1];
					if (receiver != null && parts.length > 2)
						for (index in 1...parts.length - 1)
							receiver = typedMember(receiver, parts[index], span);
					var receiverType = receiver == null ? null : receiver.type;
					var enumCase = enumCaseInfo(name);
					if (enumCase != null) {
						var expected = [
							for (param in enumCase.params)
								param.optional ? TNullable(lowerType(param.type)) : lowerType(param.type)
						];
						var required = requiredEnumParameters(enumCase.params);
						if (arguments.length < required || arguments.length > expected.length)
							fail("E1008", 'Enum constructor "$name" expects $required to ${expected.length} arguments, got ${arguments.length}', span);
						var typedArguments = [for (i in 0...arguments.length) typeExpression(arguments[i], scope, expected[i])];
						while (typedArguments.length < expected.length)
							typedArguments.push(new TypedExpression(TNullLiteral, TNull, span));
						typedArguments = coerceArguments(typedArguments, expected, name);
						return new TypedExpression(TEnumConstruct(enumCase.enumName, enumCase.index, typedArguments), TEnum(enumCase.enumName), span);
					}
					if (receiverType != null && methodName != null) {
						var stringCall = typeStringMethod(receiver, methodName, arguments, span, scope);
						if (stringCall != null)
							return stringCall;
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
						var method = signatures.get(methodKey);
						if (isGeneric(method)) {
							if (!methodInfoResult.isStatic)
								fail("E1007", "Generic instance methods are not supported yet", span);
							var genericArguments = [for (argument in arguments) typeExpression(argument, scope)];
							var specialized = specializeGeneric(methodKey, method, genericArguments, span, methodInfoResult.owner, true);
							return new TypedExpression(TCall(specialized.name, specialized.arguments), specialized.result, span);
						}
						var typed = typeDeclaredCallArguments(arguments, method.arguments, scope, methodKey, span);
						new TypedExpression(TMethodCall(receiver, methodKey, typed), lowerType(method.result), span);
					} else {
						var signature = signatures.get(name);
						if (signature != null && isGeneric(signature)) {
							var typed = [for (argument in arguments) typeExpression(argument, scope)],
								info = methodInfo.get(name),
								specialized = specializeGeneric(name, signature, typed, span, info == null ? null : info.owner,
									info == null ? true : info.isStatic);
							return new TypedExpression(TCall(specialized.name, specialized.arguments), specialized.result, span);
						}
						var external = externals.get(name),
							expectedArguments = signature == null ? (external == null ? null : external.arguments) : [for (argument in signature.arguments) argumentType(argument)],
							result = signature == null ? (external == null ? null : external.result) : lowerType(signature.result);
						if (expectedArguments == null)
							fail("E1007", 'Unknown function "$name"', span);
						if (signature == null && arguments.length != expectedArguments.length)
							fail("E1008", 'Function "$name" expects ${expectedArguments.length} arguments, got ${arguments.length}', span);
						var typed = signature == null ? typeCallArguments(arguments, expectedArguments, scope,
							name) : typeDeclaredCallArguments(arguments, signature.arguments, scope, name, span);
						new TypedExpression(TCall(name, typed), result, span);
					}
				}
			case MethodCall(object, name, arguments, span): typeMethodCall(object, name, arguments, span, scope);
		}

	function typeMember(object:AstExpression, name:String, span:SourceSpan, scope:Scope):TypedExpression {
		return typedMember(typeExpression(object, scope), name, span);
	}

	function typeSuperCall(arguments:Array<AstExpression>, span:SourceSpan, scope:Scope):TypedExpression {
		var separator = context.name.lastIndexOf("."),
			owner = separator < 0 ? null : context.name.substr(0, separator),
			classDecl = owner == null ? null : classDecls.get(owner),
			base = classDecl == null ? null : classDecl.base;
		if (base == null)
			fail("E1007", "super() requires a base-class constructor", span);
		var constructor = signatures.get(base + ".new"),
			expected = constructor == null ? PlatformAbi.constructorArguments(base) : [
				for (argument in constructor.arguments)
					argumentType(argument)
			];
		if (expected == null)
			expected = [];
		if (arguments.length != expected.length)
			fail("E1008", 'Constructor "$base" expects ${expected.length} arguments, got ${arguments.length}', span);
		return new TypedExpression(TSuperCall(base, typeCallArguments(arguments, expected, scope, base + ".new")), TVoid, span);
	}

	function seedLambdaScope(statements:Array<AstStatement>, scope:Scope):Void {
		for (statement in statements)
			switch (statement) {
				case UninitializedDeclaration(name, declared, span):
					if (scope.resolve(name) == null)
						scope.define(name, lowerType(declared), span, false);
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
				case While(_, body, _), DoWhile(body, _, _), ForIn(_, _, _, body, _):
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

	function specializeGeneric(baseName:String, fn:AstFunction, arguments:Array<TypedExpression>, span:SourceSpan, owner:Null<String>,
			isStatic:Bool):{name:String, arguments:Array<TypedExpression>, result:CompilerType} {
		if (arguments.length != fn.arguments.length)
			fail("E1008", 'Function "$baseName" expects ${fn.arguments.length} arguments, got ${arguments.length}', span);
		var substitutions:Map<String, CompilerType> = [];
		for (i in 0...arguments.length)
			inferTypeParameters(fn.arguments[i].type, arguments[i].type, fn.typeParameters, substitutions, arguments[i].span);
		for (parameter in fn.typeParameters)
			if (substitutions.get(parameter) == null)
				fail("E1003", 'Cannot infer generic type parameter "$parameter" for "$baseName"', span);
		var expected = [
			for (argument in fn.arguments)
				declarations.resolve(argument.type, argument.span, substitutions)
		], typed = coerceArguments(arguments, expected, baseName), result = declarations.resolve(fn.result, fn.span, substitutions), key = baseName + "<" + [
			for (parameter in fn.typeParameters)
				SemanticSignature.type(substitutions.get(parameter))
			].join(",") + ">", name = genericSpecializations.get(key);
		if (name == null) {
			name = '$' + 'generic:$key';
			genericSpecializations.set(key, name);
			generated.push(typeFunction(fn, owner, isStatic, substitutions, name));
		}
		return {name: name, arguments: typed, result: result};
	}

	function inferTypeParameters(pattern:AstType, actual:CompilerType, parameters:Array<String>, substitutions:Map<String, CompilerType>, span:SourceSpan):Void
		switch pattern {
			case NamedType(name) if (parameters.indexOf(name) >= 0):
				var previous = substitutions.get(name);
				if (previous != null && !sameType(previous, actual))
					fail("E1003", 'Conflicting types inferred for generic parameter "$name"', span);
				substitutions.set(name, actual);
			case ArrayType(element):
				switch actual {
					case TArray(actualElement): inferTypeParameters(element, actualElement, parameters, substitutions, span);
					default:
				}
			case MapType(key, value):
				switch actual {
					case TMap(actualKey, actualValue):
						inferTypeParameters(key, actualKey, parameters, substitutions, span);
						inferTypeParameters(value, actualValue, parameters, substitutions, span);
					default:
				}
			case NullableType(element):
				switch actual {
					case TNullable(actualElement): inferTypeParameters(element, actualElement, parameters, substitutions, span);
					default:
				}
			case FunctionType(patternArguments, patternResult):
				switch actual {
					case TFunction(actualArguments, actualResult) if (patternArguments.length == actualArguments.length):
						for (i in 0...patternArguments.length)
							inferTypeParameters(patternArguments[i], actualArguments[i], parameters, substitutions, span);
						inferTypeParameters(patternResult, actualResult, parameters, substitutions, span);
					default:
				}
			case AnonymousType(patternFields):
				switch actual {
					case TAnonymous(_, actualFields):
						for (field in patternFields) {
							var actualField = anonymousField(actualFields, field.name);
							if (actualField != null)
								inferTypeParameters(field.type, actualField.type, parameters, substitutions, span);
						}
					default:
				}
			default:
		}

	function typedMember(typedObject:TypedExpression, name:String, span:SourceSpan):TypedExpression {
		switch typedObject.expression {
			case TClassRef(className):
				var abstractDecl = enumAbstractDecls.get(className);
				if (abstractDecl != null)
					for (value in abstractDecl.values)
						if (value.name == name)
							return typeExpression(value.value, new Scope(), lowerType(abstractDecl.underlying));
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
				return {owner: className, type: lowerType(FieldInference.parsedType(field))};
		return classDecl.base == null ? null : findStaticFieldNullable(classDecl.base, name);
	}

	function typeMethodCall(object:AstExpression, name:String, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope):TypedExpression {
		var receiver = typeExpression(object, scope);
		var stringCall = typeStringMethod(receiver, name, arguments, span, scope);
		if (stringCall != null)
			return stringCall;
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
			typed = typeDeclaredCallArguments(arguments, method.arguments, scope, methodKey, span);
		return new TypedExpression(TMethodCall(receiver, methodKey, typed), lowerType(method.result), span);
	}

	function typeStringMethod(receiver:TypedExpression, name:String, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope):Null<TypedExpression> {
		if (!sameType(receiver.type, TString))
			return null;
		if (name == "indexOf") {
			if (arguments.length != 1)
				fail("E1008", 'Function "String.indexOf" expects 1 argument, got ${arguments.length}', span);
			var needle = typeExpression(arguments[0], scope);
			if (!sameType(needle.type, TString))
				fail("E1009", "String.indexOf expects a String needle", needle.span);
			return new TypedExpression(TStringIndexOf(receiver, needle), TInt, span);
		}
		if (name == "substring") {
			if (arguments.length != 2)
				fail("E1008", 'Function "String.substring" expects 2 arguments, got ${arguments.length}', span);
			var start = typeExpression(arguments[0], scope),
				end = typeExpression(arguments[1], scope);
			if (!sameType(start.type, TInt) || !sameType(end.type, TInt))
				fail("E1009", "String.substring expects Int bounds", span);
			return new TypedExpression(TStringSubstring(receiver, start, end), TString, span);
		}
		if (name == "charCodeAt") {
			if (arguments.length != 1)
				fail("E1008", 'Function "String.charCodeAt" expects 1 argument, got ${arguments.length}', span);
			var index = typeExpression(arguments[0], scope, TInt);
			if (!sameType(index.type, TInt))
				fail("E1009", "String.charCodeAt expects an Int index", index.span);
			return new TypedExpression(TStringCharCodeAt(receiver, index), TInt, span);
		}
		if (name == "charAt") {
			if (arguments.length != 1)
				fail("E1008", 'Function "String.charAt" expects 1 argument, got ${arguments.length}', span);
			var index = typeExpression(arguments[0], scope, TInt);
			if (!sameType(index.type, TInt))
				fail("E1009", "String.charAt expects an Int index", index.span);
			return new TypedExpression(TStringCharAt(receiver, index), TString, span);
		}
		return null;
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
			return new TypedExpression(TCollectionCall(receiver, "copy", []), TArray(element), span);
		}
		if (name == "concat") {
			if (arguments.length != 1)
				fail("E1008", "Array.concat expects one argument", span);
			var other = typeExpression(arguments[0], scope),
				otherElement = arrayElementType(other.type, span);
			if (!sameType(otherElement, element))
				fail("E1002", "Array.concat expects matching element types", span);
			return new TypedExpression(TCollectionCall(receiver, "concat", [other]), TArray(element), span);
		}
		if (name == "slice") {
			if (arguments.length < 1 || arguments.length > 2)
				fail("E1008", "Array.slice expects a start and optional end", span);
			var start = coerce(typeExpression(arguments[0], scope), TInt, "slice start", "E1002"),
				end = arguments.length == 2 ? coerce(typeExpression(arguments[1], scope), TInt, "slice end",
					"E1002") : new TypedExpression(TArrayLength(receiver), TInt, span);
			return new TypedExpression(TCollectionCall(receiver, "slice", [start, end]), TArray(element), span);
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
			return new TypedExpression(TCollectionCall(receiver, "index_of", [value]), TInt, span);
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
			return new TypedExpression(TCollectionCall(receiver, "set", [key, value]), TVoid, span);
		}
		if (name == "keys") {
			if (arguments.length != 0)
				fail("E1008", "Map.keys expects no arguments", span);
			return new TypedExpression(TCollectionCall(receiver, "keys", []), TArray(mapType.key), span);
		}
		if (name == "values") {
			if (arguments.length != 0)
				fail("E1008", "Map.values expects no arguments", span);
			return new TypedExpression(TCollectionCall(receiver, "values", []), TArray(mapType.value), span);
		}
		if (name == "clear") {
			if (arguments.length != 0)
				fail("E1008", "Map.clear expects no arguments", span);
			return new TypedExpression(TCollectionCall(receiver, "clear", []), TVoid, span);
		}
		if (name == "size") {
			if (arguments.length != 0)
				fail("E1008", "Map.size expects no arguments", span);
			return new TypedExpression(TCollectionCall(receiver, "size", []), TInt, span);
		}
		if (arguments.length != 1)
			fail("E1008", 'Map.$name expects one argument', span);
		var key = coerce(typeExpression(arguments[0], scope), mapType.key, "map key", "E1002");
		return switch name {
			case "exists": new TypedExpression(TCollectionCall(receiver, "exists", [key]), TBool, span);
			case "remove": new TypedExpression(TCollectionCall(receiver, "remove", [key]), TBool, span);
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
		return TFunction([for (argument in fn.arguments) argumentType(argument)], lowerType(fn.result));

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
				case DoWhile(body, _, _):
					collectAssignedLocals(body, names);
				case ForIn(name, valueName, _, body, _):
					names.set(name, true);
					if (valueName != null)
						names.set(valueName, true);
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
				case UninitializedDeclaration(name, _, _):
					names.set(name, true);
				case VarDeclaration(name, _, _, _):
					names.set(name, true);
				case If(_, yes, no, _):
					collectDeclaredLocals(yes, names);
					collectDeclaredLocals(no, names);
				case While(_, body, _):
					collectDeclaredLocals(body, names);
				case DoWhile(body, _, _):
					collectDeclaredLocals(body, names);
				case ForIn(name, valueName, _, body, _):
					names.set(name, true);
					if (valueName != null)
						names.set(valueName, true);
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
				case UninitializedDeclaration(_, _, _):
				case VarDeclaration(_, _, expression, _), Assignment(_, expression, _), Return(expression, _), Throw(expression, _), Expression(expression, _):
					collectExpressionVariables(expression, names);
				case IndexAssignment(array, offset, expression, _):
					collectExpressionVariables(array, names);
					collectExpressionVariables(offset, names);
					collectExpressionVariables(expression, names);
				case FieldAssignment(object, _, expression, _):
					collectExpressionVariables(object, names);
					collectExpressionVariables(expression, names);
				case ReturnVoid(_):
				case If(condition, yes, no, _):
					collectExpressionVariables(condition, names);
					collectVariables(yes, names);
					collectVariables(no, names);
				case While(condition, body, _):
					collectExpressionVariables(condition, names);
					collectVariables(body, names);
				case DoWhile(body, condition, _):
					collectVariables(body, names);
					collectExpressionVariables(condition, names);
				case ForIn(_, _, iterable, body, _):
					collectExpressionVariables(iterable, names);
					collectVariables(body, names);
				case Switch(expression, cases, defaultBranch, _, _):
					collectExpressionVariables(expression, names);
					for (switchCase in cases) {
						collectExpressionVariables(switchCase.value, names);
						if (switchCase.guard != null)
							collectExpressionVariables(switchCase.guard, names);
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
				case UninitializedDeclaration(_, _, _):
				case VarDeclaration(_, _, expression, _), Assignment(_, expression, _), Return(expression, _), Throw(expression, _), Expression(expression, _):
					collectMutableCaptureExpression(expression, outerDeclared, result);
				case IndexAssignment(array, offset, expression, _):
					collectMutableCaptureExpression(array, outerDeclared, result);
					collectMutableCaptureExpression(offset, outerDeclared, result);
					collectMutableCaptureExpression(expression, outerDeclared, result);
				case FieldAssignment(object, _, expression, _):
					collectMutableCaptureExpression(object, outerDeclared, result);
					collectMutableCaptureExpression(expression, outerDeclared, result);
				case If(condition, yes, no, _):
					collectMutableCaptureExpression(condition, outerDeclared, result);
					collectMutableCaptureCandidates(yes, outerDeclared, result);
					collectMutableCaptureCandidates(no, outerDeclared, result);
				case While(condition, body, _):
					collectMutableCaptureExpression(condition, outerDeclared, result);
					collectMutableCaptureCandidates(body, outerDeclared, result);
				case DoWhile(body, condition, _):
					collectMutableCaptureCandidates(body, outerDeclared, result);
					collectMutableCaptureExpression(condition, outerDeclared, result);
				case ForIn(_, _, iterable, body, _):
					collectMutableCaptureExpression(iterable, outerDeclared, result);
					collectMutableCaptureCandidates(body, outerDeclared, result);
				case Switch(expression, cases, defaultBranch, _, _):
					collectMutableCaptureExpression(expression, outerDeclared, result);
					for (switchCase in cases) {
						collectMutableCaptureExpression(switchCase.value, outerDeclared, result);
						if (switchCase.guard != null)
							collectMutableCaptureExpression(switchCase.guard, outerDeclared, result);
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
				case While(_, body, _), DoWhile(body, _, _), ForIn(_, _, _, body, _):
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
			case Add(left, right, _), Sub(left, right, _), Mul(left, right, _), Div(left, right, _), Mod(left, right, _), BitAnd(left, right, _),
				BitXor(left, right, _), BitOr(left, right, _), ShiftLeft(left, right, _), ShiftRight(left, right, _), UnsignedShiftRight(left, right, _),
				Less(left, right, _), LessEqual(left, right, _), Greater(left, right, _), GreaterEqual(left, right, _), Equal(left, right, _),
				NotEqual(left, right, _), And(left, right, _), Or(left, right, _):
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
			case PostfixIncrement(target, _, _):
				collectMutableCaptureExpression(target, outerDeclared, result);
			case Conditional(condition, whenTrue, whenFalse, _):
				for (item in [condition, whenTrue, whenFalse])
					collectMutableCaptureExpression(item, outerDeclared, result);
			case BlockExpression(statements, value, _):
				collectMutableCaptureCandidates(statements, outerDeclared, result);
				collectMutableCaptureExpression(value, outerDeclared, result);
			case ThrowExpression(value, _):
				collectMutableCaptureExpression(value, outerDeclared, result);
			case Cast(value, _, _):
				collectMutableCaptureExpression(value, outerDeclared, result);
			case SwitchExpression(subject, cases, fallback, _):
				collectMutableCaptureExpression(subject, outerDeclared, result);
				for (switchCase in cases) {
					collectMutableCaptureExpression(switchCase.value, outerDeclared, result);
					if (switchCase.guard != null)
						collectMutableCaptureExpression(switchCase.guard, outerDeclared, result);
					collectMutableCaptureExpression(switchCase.result, outerDeclared, result);
				}
				if (fallback != null)
					collectMutableCaptureExpression(fallback, outerDeclared, result);
			case ObjectLiteral(fields, _):
				for (field in fields)
					collectMutableCaptureExpression(field.value, outerDeclared, result);
			case ArrayLiteral(values, _):
				for (value in values)
					collectMutableCaptureExpression(value, outerDeclared, result);
			case MapLiteral(entries, _):
				for (entry in entries) {
					collectMutableCaptureExpression(entry.key, outerDeclared, result);
					collectMutableCaptureExpression(entry.value, outerDeclared, result);
				}
			case ArrayComprehension(_, _, iterable, condition, value, _):
				collectMutableCaptureExpression(iterable, outerDeclared, result);
				if (condition != null)
					collectMutableCaptureExpression(condition, outerDeclared, result);
				collectMutableCaptureExpression(value, outerDeclared, result);
			case MapComprehension(_, _, iterable, condition, key, value, _):
				collectMutableCaptureExpression(iterable, outerDeclared, result);
				if (condition != null)
					collectMutableCaptureExpression(condition, outerDeclared, result);
				collectMutableCaptureExpression(key, outerDeclared, result);
				collectMutableCaptureExpression(value, outerDeclared, result);
			case Range(start, end, _):
				collectMutableCaptureExpression(start, outerDeclared, result);
				collectMutableCaptureExpression(end, outerDeclared, result);
			case Variable(_, _), IntegerLiteral(_, _), FloatLiteral(_, _), StringLiteral(_, _), BoolLiteral(_, _), NullLiteral(_), Unreachable(_),
				NewMap(_, _, _):
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
			case Add(left, right, _), Sub(left, right, _), Mul(left, right, _), Div(left, right, _), Mod(left, right, _), BitAnd(left, right, _),
				BitXor(left, right, _), BitOr(left, right, _), ShiftLeft(left, right, _), ShiftRight(left, right, _), UnsignedShiftRight(left, right, _),
				Less(left, right, _), LessEqual(left, right, _), Greater(left, right, _), GreaterEqual(left, right, _), Equal(left, right, _),
				NotEqual(left, right, _):
				collectExpressionVariables(left, names);
				collectExpressionVariables(right, names);
			case Negate(value, _):
				collectExpressionVariables(value, names);
			case Not(value, _):
				collectExpressionVariables(value, names);
			case And(left, right, _), Or(left, right, _):
				collectExpressionVariables(left, names);
				collectExpressionVariables(right, names);
			case Conditional(condition, whenTrue, whenFalse, _):
				for (item in [condition, whenTrue, whenFalse])
					collectExpressionVariables(item, names);
			case BlockExpression(statements, value, _):
				collectVariables(statements, names);
				collectExpressionVariables(value, names);
			case ThrowExpression(value, _):
				collectExpressionVariables(value, names);
			case Cast(value, _, _):
				collectExpressionVariables(value, names);
			case SwitchExpression(subject, cases, fallback, _):
				collectExpressionVariables(subject, names);
				for (switchCase in cases) {
					collectExpressionVariables(switchCase.value, names);
					if (switchCase.guard != null)
						collectExpressionVariables(switchCase.guard, names);
					collectExpressionVariables(switchCase.result, names);
				}
				if (fallback != null)
					collectExpressionVariables(fallback, names);
			case ObjectLiteral(fields, _):
				for (field in fields)
					collectExpressionVariables(field.value, names);
			case ArrayLiteral(values, _):
				for (value in values)
					collectExpressionVariables(value, names);
			case MapLiteral(entries, _):
				for (entry in entries) {
					collectExpressionVariables(entry.key, names);
					collectExpressionVariables(entry.value, names);
				}
			case ArrayComprehension(_, _, iterable, condition, value, _):
				collectExpressionVariables(iterable, names);
				if (condition != null)
					collectExpressionVariables(condition, names);
				collectExpressionVariables(value, names);
			case MapComprehension(_, _, iterable, condition, key, value, _):
				collectExpressionVariables(iterable, names);
				if (condition != null)
					collectExpressionVariables(condition, names);
				collectExpressionVariables(key, names);
				collectExpressionVariables(value, names);
			case Range(start, end, _):
				collectExpressionVariables(start, names);
				collectExpressionVariables(end, names);
			case New(_, arguments, _):
				for (argument in arguments)
					collectExpressionVariables(argument, names);
			case NewArray(_, length, _):
				collectExpressionVariables(length, names);
			case NewMap(_, _, _):
			case Index(array, offset, _):
				collectExpressionVariables(array, names);
				collectExpressionVariables(offset, names);
			case PostfixIncrement(target, _, _):
				collectExpressionVariables(target, names);
			case Lambda(_, body, _):
				collectVariables(body, names);
			case IntegerLiteral(_, _):
				return;
			case FloatLiteral(_, _):
				return;
			case StringLiteral(_, _):
				return;
			case BoolLiteral(_, _), NullLiteral(_), Unreachable(_):
				return;
		}

	function coerceArguments(arguments:Array<TypedExpression>, expected:Array<CompilerType>, name:String):Array<TypedExpression> {
		var output = [];
		for (i in 0...arguments.length)
			output.push(coerce(arguments[i], expected[i], 'argument ${i + 1} to "$name"'));
		return output;
	}

	function typeCallArguments(arguments:Array<AstExpression>, expected:Array<CompilerType>, scope:Scope, name:String):Array<TypedExpression> {
		var typed = [for (i in 0...arguments.length) typeExpression(arguments[i], scope, expected[i])];
		return coerceArguments(typed, expected, name);
	}

	function typeDeclaredCallArguments(arguments:Array<AstExpression>, parameters:Array<compiler.Ast.AstArgument>, scope:Scope, name:String,
			span:SourceSpan):Array<TypedExpression> {
		var required = parameters.length;
		while (required > 0 && parameters[required - 1].optional)
			required--;
		if (arguments.length < required || arguments.length > parameters.length) {
			var expected = required == parameters.length ? '$required' : '$required to ${parameters.length}';
			fail("E1008", 'Function "$name" expects $expected arguments, got ${arguments.length}', span);
		}
		var typed = [
			for (i in 0...arguments.length)
				typeExpression(arguments[i], scope, argumentType(parameters[i]))
		];
		for (i in arguments.length...parameters.length) {
			var parameter = parameters[i], expected = argumentType(parameter);
			if (parameter.defaultValue == null)
				typed.push(coerce(new TypedExpression(TNullLiteral, TNull, span), expected, 'default argument ${i + 1} to "$name"'));
			else
				typed.push(coerce(typeExpression(parameter.defaultValue, scope, expected), expected, 'default argument ${i + 1} to "$name"'));
		}
		return coerceArguments(typed, [for (parameter in parameters) argumentType(parameter)], name);
	}

	function argumentType(argument:compiler.Ast.AstArgument):CompilerType {
		var type = lowerType(argument.type);
		return argument.optional && argument.defaultValue == null ? TNullable(type) : type;
	}

	function coerce(value:TypedExpression, expected:CompilerType, context:String, code:String = "E1009"):TypedExpression {
		if (value.type == TNever)
			return new TypedExpression(value.expression, expected, value.span);
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

	function enumCaseInfo(name:String):Null<{enumName:String, index:Int, params:Array<compiler.Ast.AstEnumParameter>}> {
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

	static function requiredEnumParameters(parameters:Array<compiler.Ast.AstEnumParameter>):Int {
		var minimum = 0;
		for (index in 0...parameters.length)
			if (!parameters[index].optional)
				minimum = index + 1;
		return minimum;
	}

	function fieldType(type:CompilerType, name:String, span:SourceSpan):CompilerType {
		switch type {
			case TAnonymous(_, fields):
				for (field in fields)
					if (field.name == name)
						return field.type;
				fail("E1005", 'Unknown anonymous field "$name"', span);
			case TClass(className):
				var classDecl = classDecls.get(className);
				if (classDecl != null) {
					for (field in classDecl.fields)
						if (field.name == name && !field.isStatic)
							return lowerType(FieldInference.parsedType(field));
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
		var ownerSeparator = context.name.lastIndexOf("."),
			owner = ownerSeparator < 0 ? null : context.name.substr(0, ownerSeparator),
			staticField = owner == null ? null : findStaticFieldNullable(owner, name);
		if (staticField != null)
			return new TypedExpression(TStaticField(staticField.owner, name), staticField.type, span);
		return null;
	}

	function findFieldType(type:CompilerType, name:String):Null<CompilerType>
		return switch type {
			case TAnonymous(_, fields):
				var found = null;
				for (field in fields)
					if (field.name == name)
						found = field.type;
				found;
			case TClass(className):
				var classDecl = classDecls.get(className),
					found:Null<CompilerType> = null;
				if (classDecl != null) {
					for (field in classDecl.fields)
						if (field.name == name && !field.isStatic)
							found = lowerType(FieldInference.parsedType(field));
					if (found == null && classDecl.base != null)
						found = findFieldType(TClass(classDecl.base), name);
				}
				found;
			default: null;
		};

	function arithmetic(a:AstExpression, b:AstExpression, scope:Scope, add:Bool, span:SourceSpan):TypedExpression {
		var left = typeExpression(a, scope), right = typeExpression(b, scope);
		if (add && sameType(left.type, TString) && sameType(right.type, TString))
			return new TypedExpression(TAdd(left, right), TString, span);
		if (!sameType(left.type, right.type) || (!sameType(left.type, TInt) && !sameType(left.type, TFloat)))
			fail("E1010", "Arithmetic requires matching Int or Float operands", span);
		return new TypedExpression(add ? TAdd(left, right) : TSub(left, right), left.type, span);
	}

	function logical(a:AstExpression, b:AstExpression, scope:Scope, and:Bool, span:SourceSpan):TypedExpression {
		var left = typeExpression(a, scope),
			rightScope = narrowedScope(scope, left, and),
			right = typeExpression(b, rightScope);
		if (!sameType(left.type, TBool) || !sameType(right.type, TBool))
			fail("E1011", "Logical operators require Bool operands", span);
		return new TypedExpression(and ? TAnd(left, right) : TOr(left, right), TBool, span);
	}

	function numeric(a:AstExpression, b:AstExpression, scope:Scope, operation:Int, span:SourceSpan):TypedExpression {
		var left = typeExpression(a, scope), right = typeExpression(b, scope);
		if (!sameType(left.type, right.type) || (!sameType(left.type, TInt) && !sameType(left.type, TFloat)))
			fail("E1010", "Arithmetic requires matching Int or Float operands", span);
		return new TypedExpression(operation == 2 ? TMul(left, right) : TDiv(left, right), left.type, span);
	}

	function modulo(a:AstExpression, b:AstExpression, scope:Scope, span:SourceSpan):TypedExpression {
		var left = typeExpression(a, scope), right = typeExpression(b, scope);
		if (!sameType(left.type, TInt) || !sameType(right.type, TInt))
			fail("E1010", "Modulo requires matching Int operands", span);
		return new TypedExpression(TMod(left, right), TInt, span);
	}

	function bitwise(a:AstExpression, b:AstExpression, scope:Scope, operation:Int, span:SourceSpan):TypedExpression {
		var left = typeExpression(a, scope), right = typeExpression(b, scope);
		if (!sameType(left.type, TInt) || !sameType(right.type, TInt))
			fail("E1010", "Bitwise operators require Int operands", span);
		var expression = switch operation {
			case 0: TBitAnd(left, right);
			case 1: TBitXor(left, right);
			case 2: TBitOr(left, right);
			case 3: TShiftLeft(left, right);
			case 4: TShiftRight(left, right);
			default: TUnsignedShiftRight(left, right);
		};
		return new TypedExpression(expression, TInt, span);
	}

	function comparison(a:AstExpression, b:AstExpression, scope:Scope, operation:Int, span:SourceSpan):TypedExpression {
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
				case TDoWhile(body, _, _):
					if (alwaysReturns(body))
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

	function alwaysExits(statements:Array<TypedStatement>):Bool {
		for (statement in statements)
			switch statement {
				case TReturn(_, _), TReturnVoid(_), TThrow(_, _), TBreak(_), TContinue(_):
					return true;
				case TIf(_, yes, no, _):
					if (no.length > 0 && alwaysExits(yes) && alwaysExits(no))
						return true;
				case TDoWhile(body, _, _):
					if (alwaysExits(body))
						return true;
				case TTry(tryBranch, catches, _):
					if (alwaysExits(tryBranch)
						&& catches.length > 0
						&& [for (catchClause in catches) alwaysExits(catchClause.statements)].indexOf(false) < 0)
						return true;
				case TSwitch(expression, cases, defaultBranch, hasDefault, _):
					if ((hasDefault ? alwaysExits(defaultBranch) : exhaustiveEnum(expression.type, cases))
						&& [for (switchCase in cases) alwaysExits(switchCase.statements)].indexOf(false) < 0)
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
		return declarations.resolve(type, null, context.typeSubstitutions);

	static function isGeneric(fn:AstFunction):Bool
		return fn.typeParameters != null && fn.typeParameters.length > 0;

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
			case TString, TDynamic, TClass(_), TInterface(_), TAnonymous(_, _), TArray(_), TFunction(_), TMap(_, _): true;
			default: false;
		};

	static function anonymousField(fields:Null<Array<compiler.types.Type.AnonymousField>>, name:String):Null<compiler.types.Type.AnonymousField> {
		if (fields != null)
			for (field in fields)
				if (field.name == name)
					return field;
		return null;
	}

	static function anonymousTypeName(fields:Array<compiler.types.Type.AnonymousField>):String
		return '$' + 'anon:{' + [for (field in fields) field.name + ":" + SemanticSignature.type(field.type)].join(",") + '}';

	function registerAnonymousTypes(type:CompilerType):Void
		switch type {
			case TAnonymous(name, fields):
				anonymousTypes.set(name, fields);
				for (field in fields)
					registerAnonymousTypes(field.type);
			case TNullable(element), TArray(element):
				registerAnonymousTypes(element);
			case TMap(key, value):
				registerAnonymousTypes(key);
				registerAnonymousTypes(value);
			case TFunction(arguments, result):
				for (argument in arguments)
					registerAnonymousTypes(argument);
				registerAnonymousTypes(result);
			default:
		}

	function orderedAnonymousTypes():Array<compiler.types.TypedAst.TypedAnonymous> {
		var names = [for (name in anonymousTypes.keys()) name];
		names.sort(Reflect.compare);
		return [for (name in names) {name: name, fields: anonymousTypes.get(name)}];
	}

	static function statementSpan(statement:AstStatement):SourceSpan
		return switch statement {
			case UninitializedDeclaration(_, _, span), VarDeclaration(_, _, _, span), Assignment(_, _, span), IndexAssignment(_, _, _, span),
				FieldAssignment(_, _, _, span), Return(_, span), ReturnVoid(span), Throw(_, span), Try(_, _, span), If(_, _, _, span), While(_, _, span),
				DoWhile(_, _,
					span), ForIn(_, _, _, _, span), Break(span), Continue(span), Switch(_, _, _, _, span), Increment(_, _, span), Expression(_, span): span;
		}

	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));

	static function sameType(left:CompilerType, right:CompilerType):Bool
		return TypeRelations.equals(left, right);
}
