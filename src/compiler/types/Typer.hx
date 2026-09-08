package compiler.types;

import compiler.syntax.Ast;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstProgram;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstInterface;
import compiler.syntax.Ast.AstEnum;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.Type.AnonymousField;
import compiler.runtime.RuntimeType;
import compiler.runtime.PlatformAbi;
import compiler.semantic.GenericSpecializationRegistry;
import compiler.semantic.GenericSpecializationPolicy;
import compiler.types.analysis.BodyContext;
import compiler.types.analysis.CaptureAnalysis;
import compiler.types.analysis.AbstractConstructorNormalizer;
import compiler.types.analysis.ClosureConversion;
import compiler.types.analysis.ControlFlow;
import compiler.types.analysis.FlowAnalysis;
import compiler.types.analysis.LexicalStorageAnalysis;
import compiler.types.analysis.Scope;
import compiler.semantic.SemanticProgram;
import compiler.semantic.SemanticProgram.SemanticMethodInfo;
import compiler.semantic.SemanticSignature;
import compiler.semantic.DeclarationLifecycle.DeclarationStage;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedExpressionKind;
import compiler.types.TypedAst.TypedEnum;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedInterface;
import compiler.types.TypedAst.TypedMapEntry;
import compiler.types.TypedAst.TypedObjectField;
import compiler.types.TypedAst.TypedClass;
import compiler.types.TypedAst.TypedCatch;
import compiler.types.TypedAst.TypedCapture;
import compiler.types.TypedAst.TypedCaptureSource;
import compiler.types.TypedAst.TypedField;
import compiler.types.TypedAst.TypedProgram;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.TypedAst.TypedSwitchBinding;
import compiler.types.TypedAst.TypedSwitchPredicate;
import compiler.types.TypedAst.TypedSwitchCase;
import compiler.types.TypedAst.TypedSwitchExpressionCase;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceSpan;

typedef TyperPhaseMetrics = {
	final declarationMs:Float;
	final shapeConnectionMs:Float;
	final signatureTypingMs:Float;
	final setupMs:Float;
	final noReturnMs:Float;
	final metadataMs:Float;
	final bodiesMs:Float;
	final bodyTransitionMs:Float;
	final assemblyMs:Float;
	final finalizationMs:Float;
}

typedef MeasuredTypedProgram = {
	final program:TypedProgram;
	final metrics:TyperPhaseMetrics;
}

/** Resolves bindings and converts parsed syntax into the typed semantic tree. */
class Typer {
	var signatures:Map<String, AstFunction> = [];
	var methodInfo:Map<String, SemanticMethodInfo> = [];
	final externals:Map<String, {arguments:Array<CompilerType>, result:CompilerType}>;
	var classDecls:Map<String, AstClass> = [];
	var interfaceDecls:Map<String, AstInterface> = [];
	var enumDecls:Map<String, AstEnum> = [];
	var enumAbstractDecls:Map<String, compiler.syntax.Ast.AstEnumAbstract> = [];
	var declarations:DeclarationIndex;
	var relations:TypeRelations;
	final closureConversion = new ClosureConversion();
	final lambdaCache:Map<String, TypedExpression> = [];
	final bodyContexts:Array<BodyContext> = [new BodyContext("")];
	var context(get, never):BodyContext;
	final anonymousTypes:Map<String, Array<compiler.types.Type.AnonymousField>> = [];
	final genericSpecializations:GenericSpecializationRegistry;
	final emittedGenericBodies:Map<String, Bool> = [];
	final noReturnFunctions:Map<String, Bool> = [];

	inline function get_context():BodyContext
		return bodyContexts[bodyContexts.length - 1];

	function enterBody(name:String, ?typeSubstitutions:Map<String, CompilerType>, ?ownerOverride:String):BodyContext {
		var owner = ownerOverride != null ? ownerOverride : StringTools.startsWith(name, "$lambda:") ? context.lexicalOwner : parentPath(name),
			body = new BodyContext(name, typeSubstitutions, owner);
		bodyContexts.push(body);
		return body;
	}

	function leaveBody(body:BodyContext):Void {
		if (context != body)
			throw "Body typing contexts must be left in stack order";
		bodyContexts.pop();
	}

	public static function type(program:AstProgram):TypedProgram
		return new Typer(null, null).typeProgramMeasured(SemanticProgram.analyze(program), null, true, null).program;

	/** Type a reusable module without requiring an executable main function. */
	public static function typeLibrary(program:AstProgram):TypedProgram
		return new Typer(null, null).typeProgramMeasured(SemanticProgram.analyze(program), null, false, null).program;

	public static function typeSelected(program:AstProgram, selected:Map<String, Bool>,
			?externals:Map<String, {arguments:Array<CompilerType>, result:CompilerType}>, ?entryPoint:String):TypedProgram
		return typeAnalyzed(SemanticProgram.analyze(program), selected, externals, entryPoint);

	public static function typeAnalyzed(semantic:SemanticProgram, selected:Map<String, Bool>,
			?externals:Map<String, {arguments:Array<CompilerType>, result:CompilerType}>, ?entryPoint:String):TypedProgram
		return typeAnalyzedMeasured(semantic, selected, externals, entryPoint).program;

	public static function typeAnalyzedMeasured(semantic:SemanticProgram, selected:Map<String, Bool>,
			?externals:Map<String, {arguments:Array<CompilerType>, result:CompilerType}>, ?entryPoint:String,
			?specializations:GenericSpecializationRegistry):MeasuredTypedProgram
		return new Typer(externals, specializations).typeProgramMeasured(semantic, selected, true, entryPoint);

	function new(externals:Null<Map<String, {arguments:Array<CompilerType>, result:CompilerType}>>, specializations:Null<GenericSpecializationRegistry>) {
		this.externals = externals == null ? [] : externals;
		this.genericSpecializations = specializations == null ? new GenericSpecializationRegistry() : specializations;
	}

	function typeProgramMeasured(semantic:SemanticProgram, selected:Null<Map<String, Bool>>, requireMain:Bool, entryPoint:Null<String>):MeasuredTypedProgram {
		var startedAt = Sys.time() * 1000.0;
		semantic.lifecycle.requireAtLeast(SignatureTyped);
		var program = semantic.program;
		declarations = semantic.declarations;
		relations = semantic.relations;
		signatures = semantic.signatures;
		methodInfo = semantic.methodInfo;
		enumDecls = declarations.enums;
		enumAbstractDecls = declarations.enumAbstracts;
		for (decl in program.enumAbstracts) {
			var emptySubstitutions:Map<String, CompilerType> = [];
			var underlying = declarations.resolve(decl.underlying, null, emptySubstitutions);
			for (value in decl.values)
				coerce(typeExpression(value.value, new Scope(), underlying), underlying, 'enum abstract value "${decl.name}.${value.name}"', "E1002");
		}
		interfaceDecls = declarations.interfaces;
		classDecls = declarations.classes;
		for (alias in program.aliases) {
			if (alias.typeParameters.length == 0) {
				var aliasType = lowerType(alias.type);
				registerAnonymousTypes(aliasType);
			}
		}
		var typedNatives:Array<compiler.types.TypedAst.TypedNative> = [];
		for (fn in program.functions) {
			if (externals.exists(fn.name))
				fail("E1000", 'Function "${fn.name}" conflicts with a registered native', fn.span);
			if (fn.isExtern == true)
				typedNatives.push(typeExtern(fn));
		}
		for (classDecl in program.classes) {
			var defaultLibrary = nativeLibrary(classDecl.name, classDecl.metadata);
			if (classDecl.isExtern == true || defaultLibrary != null) {
				for (method in classDecl.methods) {
					if (!method.isStatic)
						fail("E1021", 'Extern instance method "${classDecl.name}.${method.name}" is not supported yet', method.span);
					var nativeName = method.name.indexOf(".") >= 0 ? method.name : classDecl.name + "." + method.name;
					typedNatives.push(typeExtern(method, nativeName, null, defaultLibrary, null, defaultLibrary != null));
				}
			}
		}
		for (abstractDecl in program.abstracts)
			if (abstractDecl.isExtern == true) {
				var defaultLibrary = nativeLibrary(abstractDecl.name, abstractDecl.metadata);
				for (method in abstractDecl.methods) {
					var nativeName = method.name.indexOf(".") >= 0 ? method.name : abstractDecl.name + "." + method.name;
					var receiverType = method.isStatic
						|| method.name == "new" ? null : declarations.resolve(abstractDecl.underlying, abstractDecl.span,
							declarationTypeSubstitutions(abstractDecl.name, abstractDecl.typeParameters));
					var resultOverride = method.name == "new" ? declarations.resolve(abstractDecl.underlying, abstractDecl.span,
						declarationTypeSubstitutions(abstractDecl.name, abstractDecl.typeParameters)) : null;
					typedNatives.push(typeExtern(method, nativeName, receiverType, defaultLibrary, resultOverride));
				}
			}
		var setupDoneAt = Sys.time() * 1000.0;
		inferNoReturnFunctions();
		var noReturnDoneAt = Sys.time() * 1000.0;
		if (requireMain) {
			var main:AstFunction;
			if (entryPoint != null && signatures.exists(entryPoint))
				main = requiredMapValue(signatures, entryPoint);
			else if (entryPoint == null && signatures.exists("main"))
				main = requiredMapValue(signatures, "main");
			else if (entryPoint == null && signatures.exists("Main.main"))
				main = requiredMapValue(signatures, "Main.main");
			else
				throw 'Program must define executable entry point "${entryPoint == null ? "main" : entryPoint}"';
			if (main.arguments.length != 0 || (lowerType(main.result) != TInt && lowerType(main.result) != TVoid))
				throw 'Executable entry point "${entryPoint == null ? main.name : entryPoint}" must take no arguments and return Int or Void';
		}
		var typedEnums:Array<TypedEnum> = [
			for (enumDecl in program.enums)
				{
					name: enumDecl.name,
					cases: [
						for (caseDecl in enumDecl.cases)
							{
								name: caseDecl.name,
								params: [
									for (param in caseDecl.params)
										erasedEnumParameter(enumDecl, param)
								],
								span: caseDecl.span
							}
					],
					span: enumDecl.span
				}
		], typedInterfaces:Array<TypedInterface> = [
			for (interfaceDecl in program.interfaces)
				{
					name: interfaceDecl.name,
					bases: [for (base in interfaceDecl.bases) inheritanceName(base)],
					methods: [
						for (method in interfaceDecl.methods)
							{
								name: method.name,
								arguments: [
									for (argument in method.arguments)
										erasedInterfaceType(interfaceDecl, argument.type, argument.span)
								],
								result: erasedInterfaceType(interfaceDecl, method.result, method.span)
							}
					]
				}
			], typedClasses:Array<TypedClass> = [
			for (classDecl in program.classes)
				if (classDecl.isExtern != true
					&& nativeLibrary(classDecl.name, classDecl.metadata) == null) typeClass(classDecl, classDecls, selected)
			], typedFunctions:Array<TypedFunction> = [];
		var metadataDoneAt = Sys.time() * 1000.0;
		for (fn in program.functions)
			if (fn.isExtern != true && !isGeneric(fn) && (selected == null || selected.exists(fn.name))) {
				typedFunctions.push(typeFunction(fn));
			}
		for (classDecl in typedClasses)
			for (method in classDecl.methods)
				if (selected == null || selected.exists(method.name))
					typedFunctions.push(method);
		for (abstractDecl in program.abstracts)
			for (method in abstractDecl.methods) {
				var name = abstractDecl.name + "." + method.name;
				if (abstractDecl.isExtern != true
					&& method.isStatic
					&& !isGeneric(requiredMapValue(signatures, name))
					&& (selected == null || selected.exists(name)))
					typedFunctions.push(typeFunction(requiredMapValue(signatures, name), abstractDecl.name, true));
			}
		for (lambda in closureConversion.generatedFunctions())
			typedFunctions.push(lambda);
		for (fn in typedFunctions) {
			for (argument in fn.arguments)
				registerAnonymousTypes(argument.type);
			registerAnonymousTypes(fn.result);
		}
		for (classDecl in typedClasses)
			for (field in classDecl.fields)
				registerAnonymousTypes(field.type);
		for (interfaceDecl in typedInterfaces)
			for (method in interfaceDecl.methods) {
				for (argument in method.arguments)
					registerAnonymousTypes(argument);
				registerAnonymousTypes(method.result);
			}
		for (enumDecl in typedEnums)
			for (enumCase in enumDecl.cases)
				for (parameter in enumCase.params)
					registerAnonymousTypes(parameter);
		for (native in typedNatives) {
			for (argument in native.arguments)
				registerAnonymousTypes(argument);
			registerAnonymousTypes(native.result);
		}
		var bodiesDoneAt = Sys.time() * 1000.0;
		semantic.lifecycle.advanceAll(BodyTyped);
		var bodyTransitionDoneAt = Sys.time() * 1000.0;
		var result:TypedProgram = {
			enums: typedEnums,
			interfaces: typedInterfaces,
			classes: typedClasses,
			functions: typedFunctions,
			closurePlan: closureConversion.plan(),
			anonymousTypes: orderedAnonymousTypes(),
			natives: typedNatives
		};
		var assemblyDoneAt = Sys.time() * 1000.0;
		semantic.lifecycle.advanceAll(Finalized);
		var finalizationDoneAt = Sys.time() * 1000.0;
		return {
			program: result,
			metrics: {
				declarationMs: semantic.lifecycleMetrics.declarationMs,
				shapeConnectionMs: semantic.lifecycleMetrics.shapeConnectionMs,
				signatureTypingMs: semantic.lifecycleMetrics.signatureTypingMs,
				setupMs: setupDoneAt - startedAt,
				noReturnMs: noReturnDoneAt - setupDoneAt,
				metadataMs: metadataDoneAt - noReturnDoneAt,
				bodiesMs: bodiesDoneAt - metadataDoneAt,
				bodyTransitionMs: bodyTransitionDoneAt - bodiesDoneAt,
				assemblyMs: assemblyDoneAt - bodyTransitionDoneAt,
				finalizationMs: finalizationDoneAt - assemblyDoneAt
			}
		};
	}

	function typeExtern(fn:AstFunction, ?externalName:String, ?receiverType:CompilerType, ?defaultLibrary:String, ?resultOverride:CompilerType,
			allowStubBody:Bool = false):compiler.types.TypedAst.TypedNative {
		if (fn.statements.length != 0 && !allowStubBody)
			fail("E1021", 'Extern function "${fn.name}" cannot have a body', fn.span);
		var binding:Null<compiler.syntax.Ast.AstMetadata> = null;
		var metadata = fn.metadata;
		if (metadata != null)
			for (entry in metadata)
				if (entry.name == "hlNative") {
					if (binding != null)
						fail("E1021", 'Extern function "${fn.name}" has duplicate @:hlNative metadata', entry.span);
					binding = entry;
				}
		if (binding == null && defaultLibrary == null)
			fail("E1021", 'Extern function "${fn.name}" requires @:hlNative(library, symbol)', fn.span);
		var library = defaultLibrary, symbol = fn.name;
		if (binding != null) {
			if (binding.arguments.length != 2)
				fail("E1021", '@:hlNative requires a library and symbol string', binding.span);
			var values = metadataStrings(binding, "@:hlNative arguments must be string literals");
			library = values[0];
			symbol = values[1];
		}
		var arguments = [for (argument in fn.arguments) argumentType(argument)];
		if (receiverType != null)
			arguments.unshift(receiverType);
		return {
			name: externalName == null ? fn.name : externalName,
			library: library,
			symbol: symbol,
			arguments: arguments,
			result: resultOverride == null ? lowerType(fn.result) : resultOverride
		};
	}

	function nativeLibrary(owner:String, metadata:Null<Array<compiler.syntax.Ast.AstMetadata>>):Null<String> {
		var binding:Null<compiler.syntax.Ast.AstMetadata> = null;
		if (metadata != null)
			for (entry in metadata)
				if (entry.name == "hlNative") {
					if (binding != null)
						fail("E1021", 'Extern declaration "$owner" has duplicate @:hlNative metadata', entry.span);
					binding = entry;
				}
		if (binding == null)
			return null;
		if (binding.arguments.length != 1)
			fail("E1021", 'Declaration @:hlNative requires one library string', binding.span);
		return metadataStrings(binding, "Declaration @:hlNative library must be a string literal")[0];
	}

	function metadataStrings(metadata:compiler.syntax.Ast.AstMetadata, message:String):Array<String> {
		var values = [];
		for (argument in metadata.arguments)
			switch argument {
				case StringLiteral(value, _):
					values.push(value);
				default:
					fail("E1021", message, metadata.span);
			}
		return values;
	}

	static function declarationTypeSubstitutions(owner:String, parameters:Array<String>):Map<String, CompilerType> {
		var result:Map<String, CompilerType> = [];
		for (parameter in parameters)
			result.set(parameter, TTypeParameter(owner, parameter));
		return result;
	}

	function erasedInterfaceType(declaration:AstInterface, type:AstType, span:SourceSpan):CompilerType {
		var substitutions:Map<String, CompilerType> = [];
		for (parameter in declaration.typeParameters)
			substitutions.set(parameter, TDynamic);
		return declarations.resolve(type, span, substitutions);
	}

	function inferNoReturnFunctions():Void {
		var changed = true;
		while (changed) {
			changed = false;
			for (name => fn in signatures)
				if (!noReturnFunctions.exists(name) && astStatementsDoNotReturn(fn.statements, name)) {
					noReturnFunctions.set(name, true);
					changed = true;
				}
		}
	}

	function astStatementsDoNotReturn(statements:Array<AstStatement>, functionName:String):Bool {
		for (statement in statements)
			switch statement {
				case Throw(_, _):
					return true;
				case Expression(expression, _):
					switch expression {
						case Call(name, _, _): return noReturnFunctions.exists(qualifiedLocalCall(name, functionName));
						default: return false;
					}
				case If(_, yes, no, _) if (no.length > 0
					&& astStatementsDoNotReturn(yes, functionName)
					&& astStatementsDoNotReturn(no, functionName)):
					return true;
				case Switch(_, cases, fallback, hasDefault, _) if (hasDefault && astStatementsDoNotReturn(fallback, functionName)):
					var allExit = true;
					for (switchCase in cases)
						if (!astStatementsDoNotReturn(switchCase.statements, functionName))
							allExit = false;
					if (allExit)
						return true;
					return false;
				case VarDeclaration(_, _, _, _), UninitializedDeclaration(_, _, _), Assignment(_, _, _), IndexAssignment(_, _, _, _),
					FieldAssignment(_, _, _, _), Increment(_, _, _):
					// Continue through statements which cannot transfer control.
				default:
					return false;
			}
		return false;
	}

	static function qualifiedLocalCall(name:String, functionName:String):String {
		if (name.indexOf(".") >= 0)
			return name;
		var cursor = functionName.length - 1;
		while (cursor >= 0) {
			if (functionName.charCodeAt(cursor) == 46)
				return functionName.substring(0, cursor) + "." + name;
			cursor--;
		}
		return name;
	}

	static function parentPath(path:String):Null<String> {
		return compiler.QualifiedName.parent(path);
	}

	static function pathBeforeLast(path:String):String {
		var parent = parentPath(path);
		return parent == null ? "" : parent;
	}

	static function lastPathSegment(path:String):String {
		return compiler.QualifiedName.last(path);
	}

	static function splitPath(path:String):Array<String> {
		return compiler.QualifiedName.split(path);
	}

	static function enumName(type:Null<CompilerType>):Null<String> {
		if (type == null)
			return null;
		return switch type {
			case TInstance(Enum, name, _): name;
			case TNullable(element):
				switch element {
					case TInstance(Enum, name, _): name;
					default: null;
				}
			default: null;
		};
	}

	static function expectedFunctionType(type:Null<CompilerType>):Null<{arguments:Array<CompilerType>, result:CompilerType}> {
		if (type == null)
			return null;
		return switch type {
			case TFunction(arguments, result): {arguments: arguments, result: result};
			case TNullable(inner): expectedFunctionType(inner);
			default: null;
		};
	}

	static function anonymousFields(type:Null<CompilerType>):Null<Array<AnonymousField>> {
		if (type == null)
			return null;
		return switch type {
			case TAnonymous(_, fields): fields;
			default: null;
		};
	}

	static function objectLiteralExpectation(type:Null<CompilerType>):Null<CompilerType> {
		if (type == null)
			return null;
		return switch type {
			case TAnonymous(_, _): type;
			case TNullable(element):
				switch element {
					case TAnonymous(_, _): element;
					default: null;
				}
			default: null;
		};
	}

	static function arrayElementExpectation(type:Null<CompilerType>):Null<CompilerType> {
		if (type == null)
			return null;
		return switch type {
			case TArray(element): element;
			case TNullable(element): arrayElementExpectation(element);
			default: null;
		};
	}

	static function mapExpectation(type:Null<CompilerType>):Null<{key:CompilerType, value:CompilerType}> {
		if (type == null)
			return null;
		return switch type {
			case TMap(key, value): {key: key, value: value};
			case TNullable(element): mapExpectation(element);
			default: null;
		};
	}

	static function requiredExpression(value:Null<TypedExpression>):TypedExpression {
		if (value == null)
			throw "Expected typed expression";
		return value;
	}

	static function requiredString(value:Null<String>):String {
		if (value == null)
			throw "Expected string";
		return value;
	}

	static function requiredStrings(value:Null<Array<String>>):Array<String> {
		if (value == null)
			throw "Expected string array";
		return value;
	}

	static function requiredType(value:Null<CompilerType>):CompilerType {
		if (value == null)
			throw "Expected semantic type";
		return value;
	}

	static function requiredFunction(value:Null<AstFunction>):AstFunction {
		if (value == null)
			throw "Expected function declaration";
		return value;
	}

	function typeClass(classDecl:AstClass, classes:Map<String, AstClass>, selected:Null<Map<String, Bool>>):TypedClass {
		var isValue = hasMetadata(classDecl.metadata, "value");
		if (isValue && classDecl.base != null)
			fail("E1022", 'Value class "${classDecl.name}" cannot extend another class', classDecl.span);
		if (isValue && classDecl.interfaces.length > 0)
			fail("E1022", 'Value class "${classDecl.name}" cannot implement interfaces', classDecl.span);
		var fields:Array<TypedField> = [],
			fieldNames:Map<String, Bool> = [],
			erasedSubstitutions:Map<String, CompilerType> = [];
		for (parameter in classDecl.typeParameters)
			erasedSubstitutions.set(parameter, TDynamic);
		for (field in classDecl.fields) {
			if (fieldNames.exists(field.name))
				fail("E1000", 'Duplicate field "${classDecl.name}.${field.name}"', field.span);
			var type = declarations.resolve(declarations.resolvedFieldType(classDecl.name, field), field.span, erasedSubstitutions);
			if (type == TVoid)
				fail("E1002", 'Field "${classDecl.name}.${field.name}" cannot have type Void', field.span);
			var initializer:Null<TypedExpression> = null,
				parsedInitializer = field.initializer;
			if (parsedInitializer != null) {
				var initializerContext = enterBody(classDecl.name + ".__init", erasedSubstitutions);
				var scope = new Scope();
				if (!field.isStatic)
					scope.defineReceiver(TInstance(NominalKind.Class, classDecl.name, []), field.span);
				initializer = coerce(typeExpression(parsedInitializer, scope, type), type,
					(field.isStatic ? 'static field "${classDecl.name}.${field.name}"' : 'field "${classDecl.name}.${field.name}"'), "E1002");
				leaveBody(initializerContext);
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
		var classSemanticSubstitutions:Map<String, CompilerType> = [];
		for (parameter in classDecl.typeParameters)
			classSemanticSubstitutions.set(parameter, TTypeParameter(classDecl.name, parameter));
		for (interfaceType in classDecl.interfaces) {
			var interfaceInstance = declarations.resolve(interfaceType, classDecl.span, classSemanticSubstitutions),
				interfaceName = inheritanceName(interfaceType);
			if (!interfaceDecls.exists(interfaceName))
				fail("E1007", 'Unknown interface "$interfaceName"', classDecl.span);
			validateInterfaceImplementation(classDecl, interfaceInstance, classSemanticSubstitutions, classDecl.span);
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
				typedMethod = typeBody ? typeFunction(method, classDecl.name, method.isStatic,
					erasedSubstitutions) : methodSignature(method, classDecl.name, erasedSubstitutions);
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
				statements: instanceInitializerStatements(instanceInitializers, classDecl.name),
				cells: [],
				cellCaptures: [],
				span: classDecl.span
			});
		var parsedBase = classDecl.base, baseName:Null<String> = null;
		if (parsedBase != null)
			baseName = inheritanceName(parsedBase);
		return {
			name: classDecl.name,
			isValue: isValue,
			base: baseName,
			interfaces: [for (interfaceType in classDecl.interfaces) inheritanceName(interfaceType)],
			fields: fields,
			methods: typedMethods,
			span: classDecl.span
		};
	}

	static function hasMetadata(metadata:Array<compiler.syntax.Ast.AstMetadata>, name:String):Bool {
		for (entry in metadata)
			if (entry.name == name)
				return true;
		return false;
	}

	function methodSignature(method:AstFunction, owner:String, ?substitutions:Map<String, CompilerType>):TypedFunction
		return {
			name: owner + "." + method.name,
			owner: owner,
			isStatic: method.isStatic,
			isConstructor: method.name == "new",
			arguments: [
				for (argument in method.arguments)
					{
						name: argument.name,
						type: argumentType(argument, substitutions)
					}
			],
			result: substitutions == null ? lowerType(method.result) : declarations.resolve(method.result, method.span, substitutions),
			statements: [],
			cells: [],
			cellCaptures: [],
			span: method.span
		};

	function prependInstanceInitializers(method:TypedFunction, className:String, fields:Array<TypedField>):TypedFunction {
		var statements = instanceInitializerStatements(fields, className);
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

	static function instanceInitializerStatements(fields:Array<TypedField>, className:String):Array<TypedStatement> {
		var statements:Array<TypedStatement> = [];
		for (field in fields) {
			var initializer = field.initializer;
			if (initializer == null)
				throw 'Missing initializer for "$className.${field.name}"';
			statements.push(TFieldAssign(new TypedExpression(TLocal("this"), TInstance(NominalKind.Class, className, []), field.span), field.name,
				initializer, field.span));
		}
		return statements;
	}

	function validateInterfaceImplementation(classDecl:AstClass, interfaceInstance:CompilerType, classSubstitutions:Map<String, CompilerType>,
			span:SourceSpan):Void {
		var interfaceName = switch interfaceInstance {
			case TInstance(Interface, name, _): name;
			default:
				fail("E1007", "Implemented type must be an interface", span);
				return;
		};
		if (!interfaceDecls.exists(interfaceName))
			return;
		var interfaceDecl = interfaceDecls.get(interfaceName),
			interfaceSubstitutions = nominalSubstitutions(interfaceInstance);
		for (baseType in interfaceDecl.bases) {
			var baseInstance = declarations.resolve(baseType, interfaceDecl.span, interfaceSubstitutions),
				base = inheritanceName(baseType);
			if (!interfaceDecls.exists(base))
				fail("E1007", 'Unknown interface "$base"', span);
			validateInterfaceImplementation(classDecl, baseInstance, classSubstitutions, span);
		}
		for (method in interfaceDecl.methods) {
			var implementation = findMethod(classDecl.name, method.name);
			if (implementation == null || implementation.isStatic)
				fail("E1007", 'Class "${classDecl.name}" does not implement "$interfaceName.${method.name}"', span);
			var implementationName = implementation.owner + "." + method.name;
			if (!signatures.exists(implementationName)
				|| !sameSignature(requiredMapValue(signatures, implementationName), method, classSubstitutions, interfaceSubstitutions))
				fail("E1003", 'Method "${classDecl.name}.${method.name}" does not match interface "$interfaceName"', span);
		}
	}

	function sameSignature(left:AstFunction, right:AstFunction, ?leftSubstitutions:Map<String, CompilerType>,
			?rightSubstitutions:Map<String, CompilerType>):Bool {
		if (left.arguments.length != right.arguments.length
			|| !TypeRelations.equals(declarations.resolve(left.result, left.span, leftSubstitutions),
				declarations.resolve(right.result, right.span, rightSubstitutions)))
			return false;
		for (i in 0...left.arguments.length)
			if (!TypeRelations.equals(declarations.resolve(left.arguments[i].type, left.arguments[i].span, leftSubstitutions),
				declarations.resolve(right.arguments[i].type, right.arguments[i].span, rightSubstitutions)))
				return false;
		return true;
	}

	function typeFunction(fn:AstFunction, ?owner:String, isStatic:Bool = false, ?substitutions:Map<String, CompilerType>, ?specializedName:String,
			?abstractReceiver:CompilerType):TypedFunction {
		var functionName = specializedName == null ? (owner == null ? fn.name : owner + "." + fn.name) : specializedName;
		var functionContext = enterBody(functionName, substitutions, specializedName == null ? null : owner);
		var storage = CaptureAnalysis.analyze(fn.statements, [for (argument in fn.arguments) argument.name]);
		var lexicalStorage = LexicalStorageAnalysis.analyze(fn.statements, fn.arguments);
		for (name in storage.assigned.keys())
			context.assigned.set(name, true);
		for (binding in lexicalStorage.mutableCaptures.keys()) {
			context.storage.request(binding, '$' + 'cell:' + context.name + ':' + binding, MutableCapture);
		}
		for (binding in lexicalStorage.exceptionCells.keys()) {
			context.storage.request(binding, '$' + 'cell:' + context.name + ':' + binding, ExceptionEdge);
		}
		var scope = new Scope();
		var isConstructor = owner != null && classDecls.exists(owner) && fn.name == "new";
		if (abstractReceiver != null) {
			scope.defineReceiver(abstractReceiver, fn.span);
		} else if (owner != null && !isStatic) {
			var receiverArguments:Array<CompilerType> = [];
			if (classDecls.exists(owner))
				for (parameter in classDecls.get(owner).typeParameters)
					receiverArguments.push(context.typeSubstitutions.exists(parameter) ? context.typeSubstitutions.get(parameter) : TDynamic);
			scope.defineReceiver(TInstance(NominalKind.Class, owner, receiverArguments), fn.span);
		}
		var arguments = [];
		if (abstractReceiver != null)
			arguments.push({name: "this", type: abstractReceiver});
		for (argument in fn.arguments) {
			var type = argumentType(argument);
			scope.define(argument.name, type, argument.span);
			bindCell(argument.name, argument.span, scope, type);
			arguments.push({name: scope.requireId(argument.name), type: type});
		}
		var result = lowerType(fn.result);
		context.resultType = result;
		inferBodyLocalTypes(fn.statements, result);
		var statements = typeStatements(fn.statements, scope, result);
		if (result != TVoid && !ControlFlow.alwaysReturns(statements, function(type, cases) return this.exhaustiveEnum(type, cases)))
			fail("E1006", 'Function ${fn.name} does not return on every path', fn.span);
		var typeArguments:Null<Array<CompilerType>> = null,
			typeParameters = fn.typeParameters;
		if (specializedName != null && typeParameters != null) {
			var resolvedArguments:Array<CompilerType> = [];
			for (parameter in typeParameters) {
				if (!context.typeSubstitutions.exists(parameter))
					throw 'Missing specialization for type parameter "$parameter"';
				resolvedArguments.push(context.typeSubstitutions.get(parameter));
			}
			typeArguments = resolvedArguments;
		}
		var resultFunction:TypedFunction = {
			name: functionName,
			genericOrigin: specializedName == null ? null : (owner == null ? fn.name : owner + "." + fn.name),
			typeArguments: typeArguments,
			owner: owner,
			isStatic: isStatic,
			isConstructor: isConstructor,
			arguments: arguments,
			result: result,
			statements: statements,
			cells: copyMap(context.storage.cells),
			cellCaptures: [],
			span: fn.span
		};
		for (name in context.storage.cells.keys()) {
			if (context.storage.types.exists(name) && context.storage.kinds.exists(name))
				closureConversion.addCell(requiredMapValue(context.storage.cells, name), requiredMapValue(context.storage.types, name),
					requiredMapValue(context.storage.kinds, name));
		}
		leaveBody(functionContext);
		return resultFunction;
	}

	function boundCell(name:String, scope:Scope):Null<String> {
		var id = scope.resolveId(name);
		return id == null ? null : context.storage.cell(id);
	}

	function bindCell(name:String, span:SourceSpan, scope:Scope, type:CompilerType):Void {
		var id = scope.requireId(name);
		context.storage.bind(LexicalStorageAnalysis.key(name, span), id, type);
	}

	function typeStatements(statements:Array<AstStatement>, scope:Scope, result:Null<CompilerType>):Array<TypedStatement> {
		var output = [];
		for (statementIndex in 0...statements.length) {
			var statement = statements[statementIndex];
			if (ControlFlow.alwaysReturns(output, function(type, cases) return this.exhaustiveEnum(type, cases))) {
				if (isNoReturnPlaceholder(output, statement))
					continue;
				fail("E1012", "Unreachable statement", statementSpan(statement));
			}
			switch statement {
				case ErrorStatement(_):
					continue;
				case UninitializedDeclaration(name, declared, span):
					var declaredType = lowerType(declared);
					var declarationKey = LexicalStorageAnalysis.key(name, span);
					if (context.storage.hasCandidate(declarationKey) && context.storage.candidateKind(declarationKey) == MutableCapture)
						fail("E1023", 'Captured local "$name" must be initialized at its declaration', span);
					scope.define(name, declaredType, span, false);
					bindCell(name, span, scope, declaredType);
					output.push(TDeclare(scope.requireId(name), declaredType, span));
				case VarDeclaration(name, declared, initializer, span):
					var declaredType:Null<CompilerType>;
					if (declared == null)
						declaredType = expectedInitializerType(name, initializer, statements, statementIndex + 1);
					else
						declaredType = lowerType(declared);
					var predeclared = false;
					if (declaredType != null)
						switch initializer {
							case Lambda(_, _, _):
								scope.define(name, declaredType, span);
								predeclared = true;
							default:
						}
					var value = typeExpression(initializer, scope, declaredType);
					if (declaredType != null) {
						value = coerce(value, declaredType, 'local "$name"', "E1002");
					} else if (sameType(value.type, TNull)) {
						fail("E1002", 'Null requires an explicit nullable type for local "$name"', span);
					}
					if (!predeclared)
						scope.define(name, value.type, span);
					bindCell(name, span, scope, value.type);
					output.push(TVar(scope.requireId(name), value, span));
				case Return(expression, span):
					var expected = result == null ? context.inferredResult : result;
					var value = typeExpression(expression, scope, expected);
					if (expected == TVoid && context.contextualVoidLambda) {
						output.push(TExpression(value, span));
						output.push(TReturnVoid(span));
						continue;
					}
					if (expected == null)
						context.inferredResult = value.type;
					else
						value = coerce(value, expected, "return", "E1003");
					output.push(TReturn(value, span));
				case ReturnVoid(span):
					var expected = result == null ? context.inferredResult : result;
					if (expected == null)
						context.inferredResult = TVoid;
					else if (expected != TVoid)
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
							case TInt, TFloat, TBool, TString:
							case TInstance(kind, _, arguments):
								if (Std.string(kind) != "class")
									fail("E1022", "Unsupported catch binding type", catchClause.span);
								if (arguments.length != 0) fail("E1022", "Unsupported generic catch binding type", catchClause.span);
							default: fail("E1022", "Unsupported catch binding type", catchClause.span);
						}
						var catchScope = new Scope(scope);
						catchScopes.push(catchScope);
						catchScope.define(catchClause.name, loweredCatchType, catchClause.span);
						bindCell(catchClause.name, catchClause.span, catchScope, loweredCatchType);
						typedCatches.push({
							name: catchScope.requireId(catchClause.name),
							type: loweredCatchType,
							statements: typeStatements(catchClause.statements, catchScope, result),
							span: catchClause.span
						});
					}
					var typedTry = typeStatements(tryBranch, tryScope, result);
					output.push(TTry(typedTry, typedCatches, span));
					var continuing:Array<Scope> = [];
					if (!ControlFlow.alwaysExits(typedTry, function(type, cases) return this.exhaustiveEnum(type, cases)))
						continuing.push(tryScope);
					for (i in 0...typedCatches.length)
						if (!ControlFlow.alwaysExits(typedCatches[i].statements, function(type, cases) return this.exhaustiveEnum(type, cases)))
							continuing.push(catchScopes[i]);
					scope.mergeAssignmentsFrom(continuing);
					scope.mergeRefinementsFrom(continuing);
				case Break(span):
					if (context.loopDepth == 0)
						fail("E1017", "break is only valid inside a loop", span);
					if (!context.loopEarlyExits[context.loopDepth - 1])
						fail("E1017", "break in do-while is not supported by the current CFG backend", span);
					output.push(TBreak(span));
				case Continue(span):
					if (context.loopDepth == 0)
						fail("E1017", "continue is only valid inside a loop", span);
					if (!context.loopEarlyExits[context.loopDepth - 1])
						fail("E1017", "continue in do-while is not supported by the current CFG backend", span);
					output.push(TContinue(span));
				case Increment(name, delta, span):
					var current = scope.resolve(name);
					if (current != null && !scope.isAssigned(name))
						fail("E1023", 'Local "$name" may be used before assignment', span);
					if (current == null) {
						var dot = name.indexOf("."),
							owner = dot < 0 ? context.lexicalOwner : name.substring(0, dot),
							fieldName = dot < 0 ? name : name.substring(dot + 1, name.length),
							staticField:Null<{
								owner:String,
								type:CompilerType
							}> = null;
						if (owner != null)
							staticField = findStaticFieldNullable(owner, fieldName);
						if (staticField == null || (!sameType(staticField.type, TInt) && !sameType(staticField.type, TFloat)))
							fail("E1018", 'Increment requires a numeric local or static field "$name"', span);
						var oldValue = new TypedExpression(TStaticField(staticField.owner, fieldName), staticField.type, span),
							one:TypedExpression = sameType(staticField.type,
								TInt) ? new TypedExpression(TIntLiteral(1), TInt, span) : new TypedExpression(TFloatLiteral(1.0), TFloat, span),
							updated = delta > 0 ? new TypedExpression(TAdd(oldValue, one), staticField.type,
								span) : new TypedExpression(TSub(oldValue, one), staticField.type, span);
						output.push(TStaticFieldAssign(staticField.owner, fieldName, updated, span));
					} else if (!sameType(current, TInt) && !sameType(current, TFloat))
						fail("E1018", 'Increment requires a numeric local "$name"', span);
					else if (scope.isCapture(name)) {
						if (!scope.isCellCapture(name))
							fail("E1013", 'Captured variable "$name" requires mutable capture cells', span);
						output.push(TCellCapturedIncrement(name, scope.requireCellClass(name), current, delta, span));
					} else if (boundCell(name, scope) != null)
						output.push(TCellIncrement(scope.requireId(name), requiredString(boundCell(name, scope)), current, delta, span));
					else
						output.push(TIncrement(scope.requireId(name), delta, span));
				case Assignment(name, expression, span):
					var dot = name.lastIndexOf(".");
					if (dot < 0) {
						var expected = scope.resolveDeclared(name);
						if (expected == null) {
							var thisType = scope.resolve("this"),
								instanceField = thisType == null ? null : findFieldType(thisType, name);
							if (instanceField != null) {
								if (thisType == null)
									throw 'Missing "this" type for field "$name"';
								var value = coerce(typeExpression(expression, scope, instanceField), instanceField, 'field "$name"', "E1002");
								var receiver = new TypedExpression(TLocal("this"), thisType, span),
									propertySetter = instancePropertyAccessor(thisType, name, false);
								if (propertySetter != null)
									output.push(TExpression(new TypedExpression(TMethodCall(receiver, propertySetter, [value]), instanceField, span), span));
								else
									output.push(TFieldAssign(receiver, name, abiBoundaryCast(value, fieldRepresentationType(thisType, name, span)), span));
							} else {
								var owner = context.lexicalOwner,
									staticField:Null<{owner:String, type:CompilerType}> = null;
								if (owner != null)
									staticField = findStaticFieldNullable(owner, name);
								if (staticField == null)
									fail("E1005", 'Unknown variable "$name"', span);
								var value = coerce(typeExpression(expression, scope, staticField.type), staticField.type, 'field "$name"', "E1002");
								output.push(TStaticFieldAssign(staticField.owner, name, value, span));
							}
						} else {
							var assignedValue = typeExpression(expression, scope, expected),
								value = coerce(assignedValue, expected, 'local "$name"', "E1002");
							if (scope.isCapture(name)) {
								if (!scope.isCellCapture(name))
									fail("E1013", 'Captured variable "$name" requires mutable capture cells', span);
								output.push(TCellCapturedAssign(name, scope.requireCellClass(name), value, span));
							} else if (boundCell(name, scope) != null)
								output.push(TCellAssign(scope.requireId(name), requiredString(boundCell(name, scope)), value, span));
							else
								output.push(TAssign(scope.requireId(name), value, span));
							scope.markAssigned(name);
							scope.invalidateExpressionsForLocal(name);
							scope.refine(name, assignedValue.type);
						}
					} else {
						var objectName = name.substring(0, dot),
							fieldName = name.substring(dot + 1, name.length),
							object = unwrapNullable(typeExpression(Variable(objectName, span), scope)),
							expected:CompilerType;
						switch object.expression {
							case TClassRef(className):
								var staticField = findStaticField(className, fieldName, span);
								var value = coerce(typeExpression(expression, scope, staticField.type), staticField.type, 'field "$name"', "E1002");
								output.push(TStaticFieldAssign(staticField.owner, fieldName, value, span));
							default:
								var platformField = PlatformAbi.field(object.type, fieldName),
									expected = fieldType(object.type, fieldName, span);
								var value = coerce(typeExpression(expression, scope, expected), expected, 'field "$name"', "E1002");
								var setter:Null<String> = platformField == null ? null : platformField.set;
								if (setter != null)
									output.push(TExpression(new TypedExpression(TCall(setter, [object, value]), TVoid, span), span));
								else {
									var propertySetter = instancePropertyAccessor(object.type, fieldName, false);
									if (propertySetter != null)
										output.push(TExpression(new TypedExpression(TMethodCall(object, propertySetter, [value]), expected, span), span));
									else {
										value = abiBoundaryCast(value, fieldRepresentationType(object.type, fieldName, span));
										output.push(TFieldAssign(object, fieldName, value, span));
									}
								}
								var objectPath = FlowAnalysis.accessPath(object);
								if (objectPath != null) scope.invalidateExpression(objectPath + "." + fieldName);
						}
					}
				case IndexAssignment(array, offset, expression, span):
					var typedArray = unwrapNullable(typeExpression(array, scope)),
						typedIndex = typeExpression(offset, scope);
					switch typedArray.type {
						case TMap(key, mapValue):
							typedIndex = coerce(typedIndex, key, "map key", "E1002");
							var value = coerce(typeExpression(expression, scope, mapValue), mapValue, "map value", "E1002");
							var entryPath = FlowAnalysis.mapEntryPath(typedArray, typedIndex);
							if (entryPath != null)
								scope.refineExpression(entryPath, mapValue);
							output.push(TMapAssign(typedArray, typedIndex, value, span));
						default:
							if (typedIndex.type == TNever)
								typedIndex = coerce(typedIndex, TInt, "array index", "E1014");
							if (typedIndex.type != TInt)
								fail("E1014", "Array index must be Int", typedIndex.span);
							var element = arrayElementType(typedArray.type, span);
							var value = coerce(typeExpression(expression, scope, element), element, "array element", "E1002");
							output.push(TIndexAssign(typedArray, typedIndex, value, span));
					}
				case FieldAssignment(receiverExpression, fieldName, expression, span):
					var object = unwrapNullable(typeExpression(receiverExpression, scope)),
						value = typeExpression(expression, scope);
					switch object.expression {
						case TClassRef(className):
							var staticField = findStaticField(className, fieldName, span);
							value = coerce(value, staticField.type, 'field "$fieldName"', "E1002");
							output.push(TStaticFieldAssign(staticField.owner, fieldName, value, span));
						default:
							var platformField = PlatformAbi.field(object.type, fieldName),
								expected = fieldType(object.type, fieldName, span);
							value = coerce(value, expected, 'field "$fieldName"', "E1002");
							var setter:Null<String> = platformField == null ? null : platformField.set;
							if (setter != null)
								output.push(TExpression(new TypedExpression(TCall(setter, [object, value]), TVoid, span), span));
							else {
								var propertySetter = instancePropertyAccessor(object.type, fieldName, false);
								if (propertySetter != null)
									output.push(TExpression(new TypedExpression(TMethodCall(object, propertySetter, [value]), expected, span), span));
								else {
									value = abiBoundaryCast(value, fieldRepresentationType(object.type, fieldName, span));
									output.push(TFieldAssign(object, fieldName, value, span));
								}
							}
							var objectPath = FlowAnalysis.accessPath(object);
							if (objectPath != null) scope.invalidateExpression(objectPath + "." + fieldName);
					}
				case If(predicate, thenBranch, elseBranch, span):
					var typedCondition = typeExpression(predicate, scope);
					if (!sameType(typedCondition.type, TBool))
						fail("E1004", "If condition must be Bool", span);
					var thenScope = FlowAnalysis.narrowedScope(scope, typedCondition, true),
						elseScope = FlowAnalysis.narrowedScope(scope, typedCondition, false),
						typedThen = typeStatements(thenBranch, thenScope, result),
						typedElse = typeStatements(elseBranch, elseScope, result);
					output.push(TIf(typedCondition, typedThen, typedElse, span));
					var continuing:Array<Scope> = [];
					if (!ControlFlow.alwaysExits(typedThen, function(type, cases) return this.exhaustiveEnum(type, cases)))
						continuing.push(thenScope);
					if (elseBranch.length == 0)
						continuing.push(elseScope);
					else if (!ControlFlow.alwaysExits(typedElse, function(type, cases) return this.exhaustiveEnum(type, cases)))
						continuing.push(elseScope);
					scope.mergeAssignmentsFrom(continuing);
					scope.mergeRefinementsFrom(continuing);
					if (elseBranch.length == 0
						&& ControlFlow.alwaysExits(typedThen, function(type, cases) return this.exhaustiveEnum(type, cases)))
						FlowAnalysis.refineAfterGuard(scope, typedCondition);
				case While(predicate, body, span):
					var typedCondition = typeExpression(predicate, scope);
					if (!sameType(typedCondition.type, TBool))
						fail("E1004", "While condition must be Bool", span);
					context.loopEarlyExits[context.loopDepth] = true;
					context.loopDepth++;
					var typedBody = typeStatements(body, new Scope(scope), result);
					context.loopDepth--;
					output.push(TWhile(typedCondition, typedBody, span));
				case DoWhile(body, predicate, span):
					var bodyScope = new Scope(scope);
					context.loopEarlyExits[context.loopDepth] = false;
					context.loopDepth++;
					var typedBody = typeStatements(body, bodyScope, result);
					context.loopDepth--;
					var typedCondition = typeExpression(predicate, bodyScope);
					if (!sameType(typedCondition.type, TBool))
						fail("E1004", "Do-while condition must be Bool", span);
					output.push(TDoWhile(typedBody, typedCondition, span));
					scope.mergeAssignmentsFrom([bodyScope]);
				case ForIn(name, valueName, iterable, body, span):
					var typedIterable = unwrapNullable(typeExpression(iterable, scope)),
						originalIterable = typedIterable;
					var element:CompilerType = switch typedIterable.type {
						case TArray(element): element;
						case TRange: TInt;
						case TMap(key, value):
							var mapName = RuntimeType.mapName(key, value);
							if (mapName == null)
								fail("E1016", "This map key/value type has no compiler-owned runtime ABI", span);
							if (valueName == null) {
								typedIterable = new TypedExpression(TCollectionCall(typedIterable, "values", []), TArray(value), span);
								value;
							} else key;
						default:
							fail("E1014", "For-in iterable must be an Array or Map", span);
							TInt;
					};
					var loopScope = new Scope(scope);
					loopScope.define(name, element, span);
					bindCell(name, span, loopScope, element);
					if (valueName == null)
						switch originalIterable.expression {
							case TCollectionCall(map, "keys", []):
								var key = new TypedExpression(TLocal(loopScope.requireId(name)), element, span),
									entryPath = FlowAnalysis.mapEntryPath(map, key);
								if (entryPath != null) switch map.type {
									case TMap(_, value): loopScope.refineExpression(entryPath, value);
									default:
								}
							default:
						}
					if (valueName != null)
						switch originalIterable.type {
							case TMap(_, value):
								loopScope.define(valueName, value, span);
								bindCell(valueName, span, loopScope, value);
							default: fail("E1014", "Key/value for-in requires a Map", span);
						}
					context.loopEarlyExits[context.loopDepth] = true;
					context.loopDepth++;
					var typedBody = typeStatements(body, loopScope, result);
					context.loopDepth--;
					var valueId:Null<String> = valueName == null ? null : loopScope.requireId(valueName);
					output.push(TForIn(loopScope.requireId(name), valueId, valueName == null ? typedIterable : originalIterable, typedBody, span));
				case Switch(expression, cases, defaultBranch, hasDefault, span):
					var typedExpression = typeExpression(expression, scope);
					if (!sameType(typedExpression.type, TInt) && !sameType(typedExpression.type, TString) && !isEnum(typedExpression.type))
						fail("E1019", "Switch requires an Int, String, or enum value", typedExpression.span);
					var typedCases:Array<TypedSwitchCase> = [],
						caseScopes:Array<Scope> = [],
						seenCases:Map<String, Bool> = [];
					for (switchCase in cases) {
						var caseScope = new Scope(scope),
							subjectBinding = switchSubjectBinding(switchCase.value, typedExpression.type, caseScope),
							pattern = subjectBinding == null ? typeEnumPattern(switchCase.value, typedExpression.type, caseScope) : null,
							typedValue = subjectBinding != null ? typedExpression : pattern == null ? coerce(typeExpression(switchCase.value, scope,
								typedExpression.type), typedExpression.type, "switch case", "E1019") : pattern.value;
						var parsedGuard = switchCase.guard,
							typedGuard = parsedGuard == null ? null : coerce(typeExpression(parsedGuard, caseScope), TBool, "switch guard", "E1003");
						if (typedGuard != null)
							caseScope = FlowAnalysis.narrowedScope(caseScope, typedGuard, true);
						var typedBody = typeStatements(switchCase.statements, caseScope, result),
							constructorIndex = pattern == null ? -1 : pattern.index,
							enumName:Null<String> = pattern == null ? null : pattern.enumName,
							bindings:Array<TypedSwitchBinding> = pattern == null ? [] : pattern.bindings,
							predicates:Array<TypedSwitchPredicate> = pattern == null ? [] : pattern.predicates;
						caseScopes.push(caseScope);
						if (pattern == null) {
							var literal = enumLiteral(typedValue);
							if (literal != null) {
								enumName = literal.name;
								constructorIndex = literal.index;
							}
						}
						var caseKey = switchCaseKey(typedValue, predicates);
						if (subjectBinding != null)
							seenCases.set("$catchall", true);
						if (caseKey != null && typedGuard == null) {
							if (seenCases.exists(caseKey))
								fail("E1020", "Duplicate switch case", switchCase.span);
							seenCases.set(caseKey, true);
						}
						typedCases.push({
							value: typedValue,
							subjectBinding: subjectBinding,
							guard: typedGuard,
							statements: typedBody,
							enumName: enumName,
							constructorIndex: constructorIndex,
							bindings: bindings,
							predicates: predicates,
							span: switchCase.span
						});
					}
					if (isEnum(typedExpression.type) && !hasDefault && !seenCases.exists("$catchall")) {
						var enumName = Std.string(enumName(typedExpression.type));
						var missing:Array<String> = [];
						if (enumDecls.exists(enumName)) {
							var enumDecl = enumDecls.get(enumName);
							for (index in 0...enumDecl.cases.length)
								if (!seenCases.exists('enum:$enumName:$index'))
									missing.push(enumDecl.cases[index].name);
						}
						if (isNullableEnum(typedExpression.type) && !seenCases.exists("null"))
							missing.push("null");
						if (missing.length > 0)
							fail("E1021", 'Enum switch is missing cases: ${missing.join(", ")}', span);
					}
					var defaultScope = new Scope(scope),
						typedDefault = typeStatements(defaultBranch, defaultScope, result);
					output.push(TSwitch(typedExpression, typedCases, typedDefault, hasDefault, span));
					var continuing:Array<Scope> = [];
					for (i in 0...typedCases.length)
						if (!ControlFlow.alwaysExits(typedCases[i].statements, function(type, cases) return this.exhaustiveEnum(type, cases)))
							continuing.push(caseScopes[i]);
					if (hasDefault) {
						if (!ControlFlow.alwaysExits(typedDefault, function(type, cases) return this.exhaustiveEnum(type, cases)))
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

	static function isNoReturnPlaceholder(output:Array<TypedStatement>, statement:AstStatement):Bool {
		if (output.length == 0)
			return false;
		var previousIsNoReturn = switch output[output.length - 1] {
			case TExpression(expression, _): expression.type == TNever;
			default: false;
		};
		return previousIsNoReturn && switch statement {
			case Return(expression, _):
				switch expression {
					case NullLiteral(_): true;
					default: false;
				}
			case ReturnVoid(_): true;
			default: false;
		};
	}

	function expectedInitializerType(name:String, initializer:AstExpression, statements:Array<AstStatement>, start:Int):Null<CompilerType> {
		switch initializer {
			case NullLiteral(_):
				var assigned = assignedLocalType(name, statements, start);
				if (assigned != null)
					return TNullable(assigned);
			case ArrayLiteral(values, _) if (values.length == 0):
				var element = pushedElementType(name, statements, start);
				if (element != null)
					return TArray(element);
			default:
		}
		return usesLocalExpectedType(initializer) ? context.localExpectedTypes.get(name) : null;
	}

	function pushedElementType(name:String, statements:Array<AstStatement>, start:Int, ?bindings:Map<String, CompilerType>):Null<CompilerType> {
		var resolvedBindings:Map<String, CompilerType> = bindings == null ? [] : bindings;
		for (index in start...statements.length)
			switch statements[index] {
				case Expression(expression, _):
					var type = pushedElementFromExpression(name, expression, resolvedBindings);
					if (type != null)
						return type;
				case If(_, yes, no, _):
					var type = pushedElementType(name, yes, 0, resolvedBindings);
					if (type == null)
						type = pushedElementType(name, no, 0, resolvedBindings);
					if (type != null)
						return type;
				case While(_, body, _), DoWhile(body, _, _):
					var type = pushedElementType(name, body, 0, resolvedBindings);
					if (type != null)
						return type;
				case ForIn(keyName, valueName, iterable, body, _):
					var loopBindings = copyMap(resolvedBindings);
					switch knownExpressionType(iterable, resolvedBindings) {
						case TArray(element): loopBindings.set(keyName, element);
						case TMap(key, value):
							loopBindings.set(keyName, valueName == null ? value : key);
							if (valueName != null) loopBindings.set(valueName, value);
						case TRange: loopBindings.set(keyName, TInt);
						default:
					}
					var type = pushedElementType(name, body, 0, loopBindings);
					if (type != null)
						return type;
				case Try(tryBranch, catches, _):
					var type = pushedElementType(name, tryBranch, 0, resolvedBindings);
					if (type != null)
						return type;
					for (catchClause in catches) {
						type = pushedElementType(name, catchClause.statements, 0, resolvedBindings);
						if (type != null)
							return type;
					}
				case Switch(_, cases, defaultBranch, _, _):
					for (switchCase in cases) {
						var caseBindings = copyMap(resolvedBindings);
						collectPatternBindingTypes(switchCase.value, caseBindings);
						var type = pushedElementType(name, switchCase.statements, 0, caseBindings);
						if (type != null)
							return type;
					}
					var type = pushedElementType(name, defaultBranch, 0, resolvedBindings);
					if (type != null)
						return type;
				case VarDeclaration(shadowed, _, _, _), UninitializedDeclaration(shadowed, _, _) if (shadowed == name):
					return null;
				default:
			}
		return null;
	}

	function pushedElementFromExpression(name:String, expression:AstExpression, bindings:Map<String, CompilerType>):Null<CompilerType>
		return switch expression {
			case MethodCall(receiverExpression, methodName, arguments, _) if (methodName == "push" && arguments.length == 1):
				switch receiverExpression {
					case Variable(receiver, _) if (receiver == name): knownExpressionType(arguments[0], bindings);
					default: null;
				}
			case Call(callName, arguments, _) if (callName == name + ".push" && arguments.length == 1): knownExpressionType(arguments[0], bindings);
			default: null;
		};

	function collectPatternBindingTypes(pattern:AstExpression, bindings:Map<String, CompilerType>):Void
		switch pattern {
			case Call(name, arguments, _):
				var info = enumCaseInfo(name);
				if (info == null && name.indexOf(".") < 0) {
					var matchedName:Null<String> = null;
					for (enumName => declaration in enumDecls)
						for (enumCase in declaration.cases)
							if (enumCase.name == name
								&& arguments.length >= requiredEnumParameters(enumCase.params)
								&& arguments.length <= enumCase.params.length) {
								if (matchedName != null)
									return;
								matchedName = enumName;
							}
					if (matchedName != null)
						info = enumCaseInfo(matchedName + "." + name);
				}
				if (info != null)
					for (index in 0...arguments.length)
						if (index < info.params.length)
							switch arguments[index] {
								case Variable(binding, _) if (binding != "_"):
									bindings.set(binding, enumStorageParameterType(info.typeParameters, info.params[index]));
								default:
							}
			default:
		}

	function assignedLocalType(name:String, statements:Array<AstStatement>, start:Int):Null<CompilerType> {
		for (index in start...statements.length)
			switch statements[index] {
				case Assignment(assigned, expression, _) if (assigned == name):
					var type = knownExpressionType(expression);
					if (type != null)
						return type;
				case If(_, yes, no, _):
					var type = assignedLocalType(name, yes, 0);
					if (type == null)
						type = assignedLocalType(name, no, 0);
					if (type != null)
						return type;
				case While(_, body, _), DoWhile(body, _, _), ForIn(_, _, _, body, _):
					var type = assignedLocalType(name, body, 0);
					if (type != null)
						return type;
				case Try(tryBranch, catches, _):
					var type = assignedLocalType(name, tryBranch, 0);
					if (type != null)
						return type;
					for (catchClause in catches) {
						type = assignedLocalType(name, catchClause.statements, 0);
						if (type != null)
							return type;
					}
				case Switch(_, cases, defaultBranch, _, _):
					for (switchCase in cases) {
						var type = assignedLocalType(name, switchCase.statements, 0);
						if (type != null)
							return type;
					}
					var type = assignedLocalType(name, defaultBranch, 0);
					if (type != null)
						return type;
				case VarDeclaration(shadowed, _, _, _), UninitializedDeclaration(shadowed, _, _) if (shadowed == name):
					return null;
				default:
			}
		return null;
	}

	function knownExpressionType(expression:AstExpression, ?bindings:Map<String, CompilerType>):Null<CompilerType>
		return switch expression {
			case Variable(name, _) if (bindings != null): bindings.get(name);
			case Call(name, _, _): knownCallType(name);
			case StringLiteral(_, _): TString;
			case IntegerLiteral(_, _): TInt;
			case FloatLiteral(_, _): TFloat;
			case BoolLiteral(_, _): TBool;
			case ArrayLiteral(values, _) if (values.length > 0): var element = knownExpressionType(values[0], bindings),
					homogeneous = element != null; for (index in 1...values.length) {
					var candidate = knownExpressionType(values[index], bindings);
					if (candidate == null || element == null || !sameType(candidate, element))
						homogeneous = false;
				} homogeneous && element != null ? TArray(element) : null;
			case Range(_, _, _): TRange;
			case New(typeName, _, span):
				if (declarations.abstracts.exists(typeName)) declarations.resolve(NamedType(typeName),
					span); else classDecls.exists(typeName) ? TInstance(NominalKind.Class, typeName, []) : null;
			default: null;
		};

	function contextualExpressionType(expression:AstExpression, scope:Scope):Null<CompilerType> {
		var known = knownExpressionType(expression);
		if (known != null)
			return known;
		return switch expression {
			case Variable(name, _): name.indexOf(".") >= 0 ? typeExpression(expression, scope).type : scope.resolve(name);
			case Member(_, _, _): typeExpression(expression, scope).type;
			case Cast(_, target, _): target == null ? null : lowerType(target);
			default: null;
		};
	}

	function knownCallType(name:String):Null<CompilerType> {
		var signatureName = resolvedCallName(name);
		if (!signatures.exists(signatureName))
			return null;
		var signature = requiredMapValue(signatures, signatureName);
		return isGeneric(signature) ? null : lowerType(signature.result);
	}

	function resolvedCallName(name:String):String {
		var method = lexicalMethod(name);
		return method == null ? name : method.owner + "." + name;
	}

	function lexicalMethod(name:String):Null<SemanticMethodInfo> {
		if (name.indexOf(".") >= 0 || context.lexicalOwner == null)
			return null;
		return findMethod(context.lexicalOwner, name);
	}

	static function usesLocalExpectedType(initializer:AstExpression):Bool
		return switch initializer {
			case NullLiteral(_): true;
			case ArrayLiteral(values, _): values.length == 0;
			case MapLiteral(entries, _): entries.length == 0;
			case Conditional(_, whenTrue, whenFalse, _): containsNullLiteral(whenTrue) || containsNullLiteral(whenFalse);
			case SwitchExpression(_, _, _, _): true;
			default: false;
		};

	static function containsNullLiteral(expression:AstExpression):Bool
		return switch expression {
			case NullLiteral(_): true;
			case Conditional(_, whenTrue, whenFalse, _): containsNullLiteral(whenTrue) || containsNullLiteral(whenFalse);
			default: false;
		};

	function inferBodyLocalTypes(statements:Array<AstStatement>, result:CompilerType):Void {
		var changed = true;
		while (changed) {
			changed = inferBodyStatementConstraints(statements, result);
		}
	}

	function inferBodyStatementConstraints(statements:Array<AstStatement>, result:CompilerType):Bool {
		var changed = false;
		for (statement in statements)
			switch statement {
				case VarDeclaration(name, declared, initializer, _):
					if (declared != null)
						changed = constrainLocal(name, lowerType(declared)) || changed;
					if (context.localExpectedTypes.exists(name))
						changed = constrainLocalExpression(initializer, context.localExpectedTypes.get(name)) || changed;
				case Return(expression, _):
					changed = constrainLocalExpression(expression, result) || changed;
				case Expression(expression, _):
					changed = constrainPushedExpression(expression) || changed;
				case If(_, thenBranch, elseBranch, _):
					changed = inferBodyStatementConstraints(thenBranch, result)
						|| inferBodyStatementConstraints(elseBranch, result)
						|| changed;
				case While(_, body, _), DoWhile(body, _, _), ForIn(_, _, _, body, _):
					changed = inferBodyStatementConstraints(body, result) || changed;
				case Try(tryBranch, catches, _):
					changed = inferBodyStatementConstraints(tryBranch, result) || changed;
					for (catchClause in catches)
						changed = inferBodyStatementConstraints(catchClause.statements, result) || changed;
				case Switch(_, cases, defaultBranch, _, _):
					for (switchCase in cases)
						changed = inferBodyStatementConstraints(switchCase.statements, result) || changed;
					changed = inferBodyStatementConstraints(defaultBranch, result) || changed;
				default:
			}
		return changed;
	}

	function constrainPushedExpression(expression:AstExpression):Bool
		return switch expression {
			case MethodCall(receiverExpression, methodName, arguments, _) if (methodName == "push" && arguments.length == 1):
				switch receiverExpression {
					case Variable(receiver, _): constrainPushedValue(receiver, arguments[0]);
					default: false;
				}
			case Call(name, arguments, _) if (arguments.length == 1 && StringTools.endsWith(name, ".push")):
				constrainPushedValue(name.substring(0, name.length - 5), arguments[0]);
			default: false;
		};

	function constrainPushedValue(receiver:String, value:AstExpression):Bool
		return switch context.localExpectedTypes.get(receiver) {
			case TArray(element): constrainLocalExpression(value, element);
			default: false;
		};

	function constrainLocalExpression(expression:AstExpression, expected:CompilerType):Bool
		return switch expression {
			case Variable(name, _): constrainLocal(name, expected);
			case Call(name, arguments, _):
				var info = enumCaseInfo(name);
				var enumName:Null<String> = switch expected {
					case TInstance(Enum, value, _): value;
					case TNullable(element):
						switch element {
							case TInstance(Enum, value, _): value;
							default: null;
						}
					default: null;
				};
				if (info == null && enumName != null && name.indexOf(".") < 0)
					info = enumCaseInfo(enumName + "." + name);
				var changed = false;
				if (info != null)
					for (index in 0...arguments.length) {
						if (index >= info.params.length)
							break;
						var parameter = info.params[index],
							parameterType = enumStorageParameterType(info.typeParameters, parameter);
						changed = constrainLocalExpression(arguments[index], parameterType) || changed;
					}
				else {
					var signatureName = resolvedCallName(name);
					if (signatures.exists(signatureName)) {
						var signature = requiredMapValue(signatures, signatureName);
						if (!isGeneric(signature))
							for (index in 0...arguments.length) {
								if (index >= signature.arguments.length)
									break;
								changed = constrainLocalExpression(arguments[index], argumentType(signature.arguments[index])) || changed;
							}
					}
				}
				changed;
			case ObjectLiteral(fields, _):
				var expectedFields = switch expected {
					case TAnonymous(_, values): values;
					default: null;
				}, changed = false;
				if (expectedFields != null)
					for (field in fields) {
						var expectedField = anonymousField(expectedFields, field.name);
						if (expectedField != null)
							changed = constrainLocalExpression(field.value, expectedField.type) || changed;
					}
				changed;
			default: false;
		};

	function constrainLocal(name:String, expected:CompilerType):Bool {
		if (context.localExpectedTypes.exists(name) || expected == TVoid)
			return false;
		context.localExpectedTypes.set(name, expected);
		return true;
	}

	function commonConditionalType(left:CompilerType, right:CompilerType):Null<CompilerType> {
		if (left == TNever)
			return right;
		if (right == TNever || sameType(left, right))
			return left;
		if (isAssignable(left, right))
			return right;
		if (isAssignable(right, left))
			return left;
		return switch left {
			case TNull: right == TVoid ? null : TNullable(right);
			case TNullable(inner): sameType(inner, right) ? TNullable(inner) : null;
			default:
				switch right {
					case TNull: left == TVoid ? null : TNullable(left);
					case TNullable(inner): sameType(left, inner) ? TNullable(inner) : null;
					default: null;
				}
		};
	}

	function typeEnumPattern(value:AstExpression, expected:CompilerType, scope:Scope):Null<{
		value:TypedExpression,
		enumName:String,
		index:Int,
		bindings:Array<TypedSwitchBinding>,
		predicates:Array<TypedSwitchPredicate>
	}> {
		return switch value {
			case Call(name, arguments, span):
				var info = enumCaseInfo(name);
				if (info == null && name.indexOf(".") < 0)
					switch expected {
						case TInstance(Enum, enumName, _): info = enumCaseInfo(enumName + "." + name);
						case TNullable(inner):
							switch inner {
								case TInstance(Enum, enumName, _): info = enumCaseInfo(enumName + "." + name);
								default:
							}
						default:
					}
				if (info == null)
					return null;
				var instanceType = switch expected {
					case TInstance(Enum, _, _): expected;
					case TNullable(inner):
						switch inner {
							case TInstance(Enum, _, _): inner;
							default: TInstance(NominalKind.Enum, info.enumName, []);
						}
					default: TInstance(NominalKind.Enum, info.enumName, []);
				};
				var instanceName = switch instanceType {
					case TInstance(Enum, value, _): value;
					default: "";
				};
				if (instanceName != info.enumName)
					fail("E1019", "Enum switch case has the wrong enum type", span);
				var required = requiredEnumParameters(info.params);
				if (arguments.length < required || arguments.length > info.params.length)
					fail("E1019", 'Enum switch case "$name" expects $required to ${info.params.length} bindings', span);
				var bindings:Array<TypedSwitchBinding> = [],
					predicates:Array<TypedSwitchPredicate> = [];
				for (index in 0...arguments.length) {
					var parameter = info.params[index],
						parameterType = enumParameterType(info.typeParameters, parameter, instanceType),
						abstractName = enumAbstractPatternName(parameter.type),
						storageType = enumStorageParameterType(info.typeParameters, parameter);
					switch arguments[index] {
						case Variable(binding, bindingSpan):
							var constantName = enumAbstractPatternConstant(abstractName, binding);
							if (binding == "_") {} else if (constantName != null || binding.indexOf(".") >= 0) {
								predicates.push(typeEnumPredicate(arguments[index], parameterType, storageType, index, constantName));
							} else {
								scope.define(binding, parameterType, bindingSpan);
								bindCell(binding, bindingSpan, scope, parameterType);
								bindings.push({
									name: scope.requireId(binding),
									type: parameterType,
									storageType: storageType,
									fieldStorageType: storageType,
									index: index,
									arrayIndex: -1
								});
							}
						case ArrayLiteral(values, patternSpan):
							switch parameterType {
								case TArray(elementType):
									var elementStorage = switch storageType {
										case TArray(element): element;
										default: elementType;
									};
									predicates.push({
										value: null,
										arrayLength: values.length,
										type: parameterType,
										storageType: storageType,
										fieldStorageType: storageType,
										index: index,
										arrayIndex: -1
									});
									for (arrayIndex in 0...values.length)
										switch values[arrayIndex] {
											case Variable(binding, bindingSpan):
												if (binding != "_") {
													scope.define(binding, elementType, bindingSpan);
													bindCell(binding, bindingSpan, scope, elementType);
													bindings.push({
														name: scope.requireId(binding),
														type: elementType,
														storageType: elementStorage,
														fieldStorageType: storageType,
														index: index,
														arrayIndex: arrayIndex
													});
												}
											default:
												predicates.push(typeEnumPredicate(values[arrayIndex], elementType, elementStorage, index, null, arrayIndex,
													storageType));
										}
								default:
									fail("E1019", "Array payload pattern requires an Array value", patternSpan);
							}
						default:
							predicates.push(typeEnumPredicate(arguments[index], parameterType, storageType, index, null));
					}
				}
				{
					value: new TypedExpression(TEnumLiteral(info.enumName, info.index), instanceType, span),
					enumName: info.enumName,
					index: info.index,
					bindings: bindings,
					predicates: predicates
				};
			default: null;
		};
	}

	function switchSubjectBinding(value:AstExpression, expected:CompilerType, scope:Scope):Null<String> {
		return switch value {
			case Variable(name, span):
				// A qualified name denotes a constant, never a new pattern binding.
				if (name.indexOf(".") >= 0)
					return null;
				var info = enumCaseInfo(name);
				if (info == null && name.indexOf(".") < 0) {
					var expectedEnum = enumName(expected);
					if (expectedEnum != null)
						info = enumCaseInfo(expectedEnum + "." + name);
				}
				if (info != null) null; else if (name == "_") ""; else {
					scope.define(name, expected, span);
					bindCell(name, span, scope, expected);
					scope.requireId(name);
				}
			default: null;
		}
	}

	function typeEnumPredicate(value:AstExpression, type:CompilerType, storageType:CompilerType, index:Int, constantName:Null<String>, arrayIndex:Int = -1,
			?fieldStorageType:CompilerType):TypedSwitchPredicate {
		switch value {
			case ArrayLiteral(values, span):
				switch type {
					case TArray(_):
						return {
							value: null,
							arrayLength: values.length,
							type: type,
							storageType: storageType,
							fieldStorageType: fieldStorageType == null ? storageType : fieldStorageType,
							index: index,
							arrayIndex: arrayIndex
						};
					default:
						fail("E1019", "Array payload pattern requires an Array value", span);
				}
			default:
		}
		var resolvedValue = switch value {
			case Variable(_, span) if (constantName != null): Variable(Std.string(constantName), span);
			default: value;
		};
		var typed = coerce(typeExpression(resolvedValue, new Scope(), type), type, "enum payload pattern", "E1019");
		if (constantPatternKey(typed) == null)
			fail("E1019", "Enum switch payload patterns must be constants, local names, or '_'", typed.span);
		return {
			value: typed,
			arrayLength: -1,
			type: type,
			storageType: storageType,
			fieldStorageType: fieldStorageType == null ? storageType : fieldStorageType,
			index: index,
			arrayIndex: arrayIndex
		};
	}

	function enumAbstractPatternName(type:AstType):Null<String>
		return switch type {
			case NamedType(name), AppliedType(name, _): enumAbstractDecls.exists(name) ? name : null;
			default: null;
		};

	function enumAbstractPatternConstant(abstractName:Null<String>, name:String):Null<String> {
		if (abstractName == null)
			return null;
		var declaration = enumAbstractDecls.get(abstractName);
		if (declaration == null)
			return null;
		var memberName = lastPathSegment(name);
		for (value in declaration.values)
			if (value.name == memberName)
				return abstractName + "." + memberName;
		return null;
	}

	function enumPatternKey(name:String, index:Int, predicates:Array<TypedSwitchPredicate>):String {
		if (predicates.length == 0)
			return 'enum:$name:$index';
		var keys = [
			for (predicate in predicates)
				'${predicate.index}:${switchPredicateKey(predicate)}'
		];
		return 'enum:$name:$index:${keys.join(",")}';
	}

	function switchPredicateKey(predicate:TypedSwitchPredicate):String {
		if (predicate.arrayLength >= 0)
			return 'array-length:${predicate.arrayLength}';
		var value = predicate.value;
		if (value == null)
			throw "Equality payload predicate has no value";
		return Std.string(constantPatternKey(value));
	}

	function switchCaseKey(value:TypedExpression, predicates:Array<TypedSwitchPredicate>):Null<String>
		return switch value.expression {
			case TIntLiteral(v): 'int:$v';
			case TStringLiteral(v): 'string:$v';
			case TEnumLiteral(name, index): enumPatternKey(name, index, predicates);
			case TNullLiteral: "null";
			case TNullableWrap(inner): switchCaseKey(inner, predicates);
			default: null;
		};

	static function enumLiteral(value:TypedExpression):Null<{name:String, index:Int}>
		return switch value.expression {
			case TEnumLiteral(name, index): {name: name, index: index};
			case TNullableWrap(inner), TCast(inner), TAbiCast(inner): enumLiteral(inner);
			default: null;
		};

	function constantPatternKey(value:TypedExpression):Null<String>
		return switch value.expression {
			case TIntLiteral(v): 'int:$v';
			case TBoolLiteral(v): 'bool:$v';
			case TStringLiteral(v): 'string:$v';
			case TEnumLiteral(name, index): 'enum:$name:$index';
			case TNullLiteral: "null";
			case TNullableWrap(inner): constantPatternKey(inner);
			case TCast(inner), TAbiCast(inner): constantPatternKey(inner);
			default: null;
		};

	function typeExpression(expression:AstExpression, scope:Scope, ?expectedType:CompilerType, inferDynamicLambdaResult:Bool = false):TypedExpression
		return switch expression {
			case IntegerLiteral(value, span): new TypedExpression(TIntLiteral(value), TInt, span);
			case FloatLiteral(value, span): new TypedExpression(TFloatLiteral(value), TFloat, span);
			case StringLiteral(value, span): new TypedExpression(TStringLiteral(value), TString, span);
			case BoolLiteral(value, span): new TypedExpression(TBoolLiteral(value), TBool, span);
			case NullLiteral(span): new TypedExpression(TNullLiteral, TNull, span);
			case Unreachable(span): new TypedExpression(TUnreachable, TNever, span);
			case ErrorExpression(span): new TypedExpression(TNullLiteral, TDynamic, span);
			case Variable(name, span):
				var type = scope.resolve(name);
				if (type != null) {
					if (!scope.isAssigned(name))
						fail("E1023", 'Local "$name" may be used before assignment', span);
					new TypedExpression(scope.isCapture(name) ? (scope.isCellCapture(name) ? TCellCaptured(name,
						scope.requireCellClass(name)) : TCaptured(name)) : (boundCell(name,
							scope) != null ? TCellLocal(scope.requireId(name),
								requiredString(boundCell(name, scope))) : TLocal(name == "this" ? name : scope.requireId(name))),
						type, span);
				} else {
					var localMethod = lexicalMethod(name);
					if (localMethod != null && !localMethod.isStatic)
						return typeMember(Variable("this", span), name, span, scope);
					var functionName = localMethod == null ? name : localMethod.owner + "." + name;
					var expectedFunction = expectedFunctionType(expectedType);
					if (name == "Reflect.compare"
						&& expectedFunction != null
						&& expectedFunction.arguments.length == 2
						&& sameType(expectedFunction.arguments[0], TString)
						&& sameType(expectedFunction.arguments[1], TString)
						&& sameType(expectedFunction.result, TInt))
						new TypedExpression(TFunctionRef("__string_compare_full"), TFunction([TString, TString], TInt), span);
					else if (signatures.exists(functionName))
						new TypedExpression(TFunctionRef(functionName), functionType(requiredMapValue(signatures, functionName)), span);
					else if (externals.exists(name)) {
						var external = externals.get(name);
						new TypedExpression(TFunctionRef(name), TFunction(external.arguments, external.result), span);
					} else if (classDecls.exists(name) || enumAbstractDecls.exists(name) || PlatformAbi.isType(name))
						new TypedExpression(TClassRef(name), TInstance(NominalKind.Class, name, []), span);
					else {
						var owner = context.lexicalOwner,
							staticField:Null<{owner:String, type:CompilerType}> = null;
						if (owner != null)
							staticField = findStaticFieldNullable(owner, name);
						if (staticField != null)
							return new TypedExpression(TStaticField(staticField.owner, name), staticField.type, span);
						var dot = name.indexOf(".");
						if (dot <= 0) {
							var expectedEnumName = enumName(expectedType);
							if (expectedEnumName != null && enumDecls.exists(expectedEnumName)) {
								var expectedEnum = enumDecls.get(expectedEnumName);
								for (index in 0...expectedEnum.cases.length) {
									var enumCase = expectedEnum.cases[index];
									if (enumCase.name == name && enumCase.params.length == 0) {
										var literalType:CompilerType = TInstance(NominalKind.Enum, expectedEnum.name, []);
										var resolvedExpected = expectedType;
										if (resolvedExpected != null)
											switch resolvedExpected {
												case TInstance(Enum, _, arguments): literalType = TInstance(NominalKind.Enum, expectedEnum.name, arguments);
												case TNullable(element):
													switch element {
														case TInstance(Enum, _,
															arguments): literalType = TInstance(NominalKind.Enum, expectedEnum.name, arguments);
														default:
													}
												default:
											}
										return new TypedExpression(TEnumLiteral(expectedEnum.name, index), literalType, span);
									}
								}
							}
							var expectedAbstractName = switch expectedType {
								case TAbstract(declaration, _, _): declaration;
								default: null;
							};
							var expectedAbstract = expectedAbstractName == null ? null : enumAbstractDecls.get(expectedAbstractName);
							if (expectedAbstract == null && expectedAbstractName != null)
								for (candidateName => candidate in enumAbstractDecls)
									if (lastPathSegment(candidateName) == lastPathSegment(expectedAbstractName)) {
										expectedAbstract = candidate;
										break;
									}
							if (expectedAbstract != null) {
								for (value in expectedAbstract.values)
									if (value.name == name)
										return typeExpression(value.value, new Scope(), lowerType(expectedAbstract.underlying));
							}
							var unqualifiedAbstract:Null<compiler.syntax.Ast.AstEnumAbstract> = null;
							for (candidate in enumAbstractDecls)
								for (value in candidate.values)
									if (value.name == name) {
										if (unqualifiedAbstract != null)
											fail("E1005", 'Ambiguous enum abstract value "$name"', span);
										unqualifiedAbstract = candidate;
									}
							if (unqualifiedAbstract != null)
								for (value in unqualifiedAbstract.values)
									if (value.name == name)
										return typeExpression(value.value, new Scope(), lowerType(unqualifiedAbstract.underlying));
							var thisType = scope.resolve("this");
							if (thisType == null)
								fail("E1005", 'Unknown variable "$name"', span);
							var field = findFieldType(thisType, name);
							if (field == null)
								fail("E1005", 'Unknown variable "$name"', span);
							typedMemberWithFlow(typeExpression(Variable("this", span), scope), name, span, scope);
						} else {
							var parts = splitPath(name),
								objectName = parts[0],
								fieldName = parts[1],
								enumName = pathBeforeLast(name),
								enumCaseName = lastPathSegment(name);
							if (enumAbstractDecls.exists(enumName)) {
								var enumAbstract = enumAbstractDecls.get(enumName);
								for (value in enumAbstract.values)
									if (value.name == enumCaseName)
										return typeExpression(value.value, new Scope(), lowerType(enumAbstract.underlying));
							}
							if (enumDecls.exists(enumName)) {
								var enumDecl = enumDecls.get(enumName);
								var index = -1;
								for (i in 0...enumDecl.cases.length)
									if (enumDecl.cases[i].name == enumCaseName)
										index = i;
								if (index < 0)
									fail("E1005", 'Unknown enum case "$name"', span);
								if (enumDecl.cases[index].params.length > 0)
									fail("E1008", 'Enum case "$name" requires constructor arguments', span);
								var literalType:CompilerType = TInstance(NominalKind.Enum, enumName, []);
								var expectedEnumName = Typer.enumName(expectedType);
								if (expectedEnumName == enumName) {
									var resolvedExpected = expectedType;
									if (resolvedExpected != null)
										switch resolvedExpected {
											case TInstance(Enum, _, arguments): literalType = TInstance(NominalKind.Enum, enumName, arguments);
											case TNullable(element):
												switch element {
													case TInstance(Enum, _, arguments): literalType = TInstance(NominalKind.Enum, enumName, arguments);
													default:
												}
											default:
										}
								}
								return new TypedExpression(TEnumLiteral(enumName, index), literalType, span);
							}
							var classEnd = parts.length - 1;
							while (classEnd > 0) {
								var className = parts.slice(0, classEnd).join(".");
								if (classDecls.exists(className) || enumAbstractDecls.exists(className) || PlatformAbi.isType(className)) {
									var classObject = new TypedExpression(TClassRef(className), TInstance(NominalKind.Class, className, []), span);
									for (index in classEnd...parts.length)
										classObject = typedMember(classObject, parts[index], span);
									return classObject;
								}
								classEnd--;
							}
							var object = typeExpression(Variable(objectName, span), scope);
							for (index in 1...parts.length)
								object = typedMemberWithFlow(object, parts[index], span, scope);
							object;
						}
					}
				}
			case Lambda(arguments, body, span):
				var lambdaKey = '${context.name}:${span.file.path}:${span.start}';
				if (lambdaCache.exists(lambdaKey)) lambdaCache.get(lambdaKey) else {
					var expectedFunction = expectedFunctionType(expectedType),
						inferContextualResult = expectedFunction != null && expectedFunction.result == TDynamic && inferDynamicLambdaResult;
					if (expectedFunction != null && expectedFunction.arguments.length != arguments.length)
						fail("E1008", 'Lambda expects ${expectedFunction.arguments.length} arguments, got ${arguments.length}', span);
					var lambdaArguments:Array<{name:String, type:CompilerType}> = [],
						lambdaScope = new Scope(),
						declared:Map<String, Bool> = [];
					for (i in 0...arguments.length) {
						var argument = arguments[i],
							localName = argument.name == "_" ? '$' + 'discard:$i' : argument.name;
						var argumentType = argument.type == InferredType ? (expectedFunction == null ? null : expectedFunction.arguments[i]) : lowerType(argument.type);
						if (argumentType == null)
							fail("E1003", 'Cannot infer lambda parameter "${argument.name}" without a function context', argument.span);
						if (expectedFunction != null && !TypeRelations.equals(argumentType, expectedFunction.arguments[i]))
							fail("E1003", "Lambda argument type does not match its context", argument.span);
						lambdaScope.define(localName, argumentType, argument.span);
						lambdaArguments.push({name: lambdaScope.requireId(localName), type: argumentType});
						if (argument.name != "_")
							declared.set(argument.name, true);
					}
					CaptureAnalysis.collectDeclaredLocals(body, declared);
					var freeVariables:Map<String, Bool> = [];
					CaptureAnalysis.collectVariables(body, freeVariables);
					// An unqualified instance method in a lambda is resolved through the
					// lexical receiver even though `this` is not present in the syntax.
					if (scope.resolve("this") != null)
						for (name in freeVariables.keys()) {
							if (scope.resolve(name) == null) {
								var method = lexicalMethod(name),
									receiverType = scope.resolve("this");
								if (method != null
									&& !method.isStatic
									|| receiverType != null
									&& findFieldType(receiverType, name) != null)
									freeVariables.set("this", true);
							}
						}
					var captures:Array<TypedCapture> = [],
						captureCells:Map<String, String> = [],
						captureTypes:Map<String, CompilerType> = [];
					for (name in freeVariables.keys())
						if (!declared.exists(name)) {
							var capturedType = scope.resolve(name);
							if (capturedType != null) {
								var captureType:CompilerType = capturedType;
								var cellClass:Null<String> = null;
								if (boundCell(name, scope) != null)
									cellClass = boundCell(name, scope);
								if (cellClass == null && scope.isCellCapture(name))
									cellClass = scope.requireCellClass(name);
								if (cellClass == null && context.assigned.exists(name)) {
									var newCellClass = '$' + 'cell:' + context.name + ':' + name;
									var bindingId = scope.requireId(name);
									cellClass = context.storage.requestBinding(bindingId, newCellClass, MutableCapture, captureType);
								}
								var bindingId = scope.requireId(name),
									captureSource:TypedCaptureSource = if (scope.isCellCapture(name)) CaptureCellEnvironmentField(name,
										scope.requireCellClass(name)) else if (scope.isCapture(name)) CaptureEnvironmentField(name) else if (cellClass != null)
										CaptureCellLocal(bindingId, cellClass) else if (scope.isReceiver(name)) CaptureReceiver else CaptureLocal(bindingId);
								lambdaScope.defineCapture(name, captureType, span, cellClass != null, cellClass, bindingId);
								if (cellClass != null)
									captureCells.set(name, cellClass);
								captureTypes.set(name, captureType);
								captures.push({
									field: name,
									bindingId: bindingId,
									type: captureType,
									source: captureSource
								});
							}
						}
					var typedBodyScope = new Scope();
					for (i in 0...lambdaArguments.length) {
						var localName = arguments[i].name == "_" ? '$' + 'discard:$i' : arguments[i].name;
						typedBodyScope.define(localName, lambdaArguments[i].type, arguments[i].span);
						lambdaArguments[i] = {name: typedBodyScope.requireId(localName), type: lambdaArguments[i].type};
					}
					for (capture in captures)
						typedBodyScope.defineCapture(capture.field, capture.type, span, captureCells.exists(capture.field), captureCells.get(capture.field),
							capture.bindingId);
					var outerContext = context,
						lambdaName = '$' + 'lambda:${outerContext.name}:${span.start}',
						lambdaContext = enterBody(lambdaName, outerContext.typeSubstitutions);
					context.resultType = expectedFunction == null || inferContextualResult ? TVoid : expectedFunction.result;
					context.contextualVoidLambda = expectedFunction != null && expectedFunction.result == TVoid;
					CaptureAnalysis.collectAssignedLocals(body, context.assigned);
					var lambdaStorage = LexicalStorageAnalysis.analyze(body, arguments);
					for (binding in lambdaStorage.mutableCaptures.keys()) {
						context.storage.request(binding, '$' + 'cell:' + lambdaName + ':' + binding, MutableCapture);
					}
					for (binding in lambdaStorage.exceptionCells.keys())
						context.storage.request(binding, "$cell:" + lambdaName + ":" + binding, ExceptionEdge);
					for (i in 0...arguments.length)
						bindCell(arguments[i].name == "_" ? "$discard:" + i : arguments[i].name, arguments[i].span, typedBodyScope, lambdaArguments[i].type);
					var typedBody = typeStatements(body, typedBodyScope, expectedFunction == null
						|| inferContextualResult ? null : expectedFunction.result);
					var inferredResult:CompilerType;
					if (expectedFunction != null && !inferContextualResult)
						inferredResult = expectedFunction.result;
					else {
						var contextualResult = context.inferredResult;
						inferredResult = contextualResult == null ? CompilerType.TVoid : contextualResult;
					}
					context.resultType = inferredResult;
					var lambdaCells = copyMap(context.storage.cells),
						lambdaCellTypes = copyMap(context.storage.types),
						lambdaCellKinds = copyMap(context.storage.kinds);
					leaveBody(lambdaContext);
					if (inferredResult != TVoid
						&& !ControlFlow.alwaysReturns(typedBody, function(type, cases) return this.exhaustiveEnum(type, cases)))
						fail("E1006", 'Function $lambdaName does not return on every path', span);
					var environment:Null<String> = null;
					if (captures.length > 0)
						environment = '$' + 'lambda-env:${context.name}:${span.start}';
					if (environment != null)
						closureConversion.addEnvironment(environment, captures);
					closureConversion.addFunction({
						name: lambdaName,
						genericOrigin: outerContext.name,
						owner: environment,
						isStatic: environment == null,
						isConstructor: false,
						arguments: lambdaArguments,
						result: inferredResult,
						statements: typedBody,
						cells: lambdaCells,
						cellCaptures: copyMap(captureCells),
						span: span
					});
					for (name in lambdaCells.keys())
						if (lambdaCellTypes.exists(name) && lambdaCellKinds.exists(name))
							closureConversion.addCell(requiredMapValue(lambdaCells, name), requiredMapValue(lambdaCellTypes, name),
								requiredMapValue(lambdaCellKinds, name));
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
			case Conditional(predicate, whenTrue, whenFalse, span):
				var typedCondition = typeExpression(predicate, scope, TBool);
				if (!sameType(typedCondition.type, TBool))
					fail("E1011", "Conditional expression requires a Bool condition", span);
				var trueScope = FlowAnalysis.narrowedScope(scope, typedCondition, true),
					falseScope = FlowAnalysis.narrowedScope(scope, typedCondition, false);
				var contextualType = expectedType;
				if (contextualType == null) {
					contextualType = contextualExpressionType(whenTrue, trueScope);
					if (contextualType == null)
						contextualType = contextualExpressionType(whenFalse, falseScope);
					if (contextualType != null
						&& !isNullable(contextualType)
						&& contextualType != TNull
						&& (containsNullLiteral(whenTrue) || containsNullLiteral(whenFalse)))
						contextualType = TNullable(contextualType);
				}
				var typedTrue = typeExpression(whenTrue, trueScope, contextualType),
					branchExpected = expectedType == null
						&& typedTrue.type != TNull
						&& typedTrue.type != TNever ? (containsNullLiteral(whenFalse) ? CompilerType.TNullable(typedTrue.type) : typedTrue.type) : expectedType,
					typedFalse = typeExpression(whenFalse, falseScope, branchExpected),
					resultType = expectedType == null ? commonConditionalType(typedTrue.type, typedFalse.type) : expectedType;
				if (resultType == null)
					fail("E1003", "Conditional branches must have matching types", span);
				typedTrue = coerce(typedTrue, resultType, "conditional branch", "E1003");
				typedFalse = coerce(typedFalse, resultType, "conditional branch", "E1003");
				new TypedExpression(TConditional(typedCondition, typedTrue, typedFalse), resultType, span);
			case BlockExpression(statements, result, span):
				var blockScope = new Scope(scope),
					typedStatements = typeStatements(statements, blockScope, context.resultType);
				if (ControlFlow.alwaysExits(typedStatements, function(type, cases) return this.exhaustiveEnum(type, cases)))
					return new TypedExpression(TBlockExpression(typedStatements, new TypedExpression(TUnreachable, TNever, span)), TNever, span);
				var typedResult = typeExpression(result, blockScope, expectedType);
				if (typedResult.type != TNever) {
					scope.mergeAssignmentsFrom([blockScope]);
					scope.mergeRefinementsFrom([blockScope]);
				}
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
				var operation:TypedExpressionKind = switch typedTarget.expression {
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
				var typedCases:Array<TypedSwitchExpressionCase> = [],
					seenCases:Map<String, Bool> = [],
					resultType = expectedType;
				for (switchCase in cases) {
					var caseScope = new Scope(scope),
						subjectBinding = switchSubjectBinding(switchCase.value, typedSubject.type, caseScope),
						pattern = subjectBinding == null ? typeEnumPattern(switchCase.value, typedSubject.type, caseScope) : null,
						typedValue = subjectBinding != null ? typedSubject : pattern == null ? coerce(typeExpression(switchCase.value, scope,
							typedSubject.type), typedSubject.type, "switch case", "E1019") : pattern.value;
					var parsedGuard = switchCase.guard,
						typedGuard = parsedGuard == null ? null : coerce(typeExpression(parsedGuard, caseScope), TBool, "switch guard", "E1003");
					if (typedGuard != null)
						caseScope = FlowAnalysis.narrowedScope(caseScope, typedGuard, true);
					var typedResult = typeExpression(switchCase.result, caseScope, expectedType == null ? resultType : expectedType),
						enumName:Null<String> = pattern == null ? null : pattern.enumName,
						constructorIndex = pattern == null ? -1 : pattern.index,
						predicates:Array<TypedSwitchPredicate> = pattern == null ? [] : pattern.predicates;
					if (expectedType == null && typedResult.type != TNever) {
						var joined = resultType == null ? typedResult.type : commonConditionalType(resultType, typedResult.type);
						if (joined == null)
							fail("E1003", "Switch branches must have matching types", switchCase.span);
						resultType = joined;
					}
					if (pattern == null) {
						var literal = enumLiteral(typedValue);
						if (literal != null) {
							enumName = literal.name;
							constructorIndex = literal.index;
						}
					}
					var caseKey = switchCaseKey(typedValue, predicates);
					if (subjectBinding != null)
						seenCases.set("$catchall", true);
					if (caseKey != null && typedGuard == null) {
						if (seenCases.exists(caseKey))
							fail("E1020", "Duplicate switch case", switchCase.span);
						seenCases.set(caseKey, true);
					}
					typedCases.push({
						value: typedValue,
						subjectBinding: subjectBinding,
						guard: typedGuard,
						result: typedResult,
						enumName: enumName,
						constructorIndex: constructorIndex,
						bindings: pattern == null ? [] : pattern.bindings,
						predicates: predicates
					});
				}
				var typedDefault = defaultExpression == null ? null : typeExpression(defaultExpression, scope,
					expectedType == null ? resultType : expectedType);
				if (typedDefault != null) {
					if (expectedType == null && typedDefault.type != TNever) {
						var joined = resultType == null ? typedDefault.type : commonConditionalType(resultType, typedDefault.type);
						if (joined == null)
							fail("E1003", "Switch branches must have matching types", span);
						resultType = joined;
					}
				}
				if (resultType == null)
					fail("E1003", "Switch expression has no result branches", span);
				typedCases = [
					for (switchCase in typedCases)
						{
							value: switchCase.value,
							subjectBinding: switchCase.subjectBinding,
							guard: switchCase.guard,
							result: coerce(switchCase.result, resultType, "switch branch", "E1003"),
							enumName: switchCase.enumName,
							constructorIndex: switchCase.constructorIndex,
							bindings: switchCase.bindings,
							predicates: switchCase.predicates
						}
				];
				if (typedDefault != null)
					typedDefault = coerce(typedDefault, resultType, "switch branch", "E1003");
				if (typedDefault == null && !isEnum(typedSubject.type))
					fail("E1021", "Switch expression requires a default branch", span);
				if (isEnum(typedSubject.type) && typedDefault == null && !seenCases.exists("$catchall")) {
					var enumName = Std.string(enumName(typedSubject.type)),
						missing:Array<String> = [];
					if (enumDecls.exists(enumName)) {
						var enumDecl = enumDecls.get(enumName);
						for (index in 0...enumDecl.cases.length)
							if (!seenCases.exists('enum:$enumName:$index'))
								missing.push(enumDecl.cases[index].name);
					}
					if (isNullableEnum(typedSubject.type) && !seenCases.exists("null"))
						missing.push("null");
					if (missing.length > 0)
						fail("E1021", 'Enum switch is missing cases: ${missing.join(", ")}', span);
				}
				new TypedExpression(TSwitchExpression(typedSubject, typedCases, typedDefault), resultType, span);
			case ObjectLiteral(fields, span):
				var objectExpected = objectLiteralExpectation(expectedType),
					expectedFields = anonymousFields(objectExpected);
				var seen:Map<String, Bool> = [],
					typedFields:Array<TypedObjectField> = [];
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
				var resolvedResult:CompilerType;
				if (objectExpected == null) {
					var inferred:Array<AnonymousField> = [
						for (field in typedFields)
							{name: field.name, type: field.value.type, optional: false}
					];
					inferred.sort(function(left, right) return Reflect.compare(left.name, right.name));
					resolvedResult = TAnonymous(anonymousTypeName(inferred), inferred);
				} else
					resolvedResult = objectExpected;
				var typeName = switch resolvedResult {
					case TAnonymous(name, _): name;
					default: "";
				};
				registerAnonymousTypes(resolvedResult);
				new TypedExpression(TObjectLiteral(typeName, typedFields), resolvedResult, span);
			case ArrayLiteral(values, span):
				var expectedMap = mapExpectation(expectedType);
				if (values.length == 0 && expectedMap != null)
					return new TypedExpression(TMapLiteral([]), TMap(expectedMap.key, expectedMap.value), span);
				var expectedElement = arrayElementExpectation(expectedType);
				if (values.length == 0 && expectedElement == null)
					fail("E1003", "Empty array literal requires an expected element type", span);
				var typedValues:Array<TypedExpression> = [],
					elementType = expectedElement;
				for (value in values) {
					var typedValue = typeExpression(value, scope, elementType),
						resolvedElement:CompilerType;
					if (elementType == null) {
						resolvedElement = typedValue.type;
						elementType = resolvedElement;
					} else
						resolvedElement = elementType;
					typedValues.push(coerce(typedValue, resolvedElement, "array element", "E1003"));
				}
				if (elementType == null)
					throw "Array element type was not resolved";
				new TypedExpression(TArrayLiteral(typedValues), TArray(elementType), span);
			case MapLiteral(entries, span):
				var expected = mapExpectation(expectedType),
					keyType = expected == null ? null : expected.key,
					valueType = expected == null ? null : expected.value,
					typedEntries:Array<TypedMapEntry> = [];
				for (entry in entries) {
					var key = typeExpression(entry.key, scope, keyType),
						value = typeExpression(entry.value, scope, valueType),
						resolvedKey:CompilerType,
						resolvedValue:CompilerType;
					if (keyType == null) {
						resolvedKey = key.type;
						keyType = resolvedKey;
					} else
						resolvedKey = keyType;
					if (valueType == null) {
						resolvedValue = value.type;
						valueType = resolvedValue;
					} else
						resolvedValue = valueType;
					typedEntries.push({
						key: coerce(key, resolvedKey, "map key", "E1003"),
						value: coerce(value, resolvedValue, "map value", "E1003")
					});
				}
				if (keyType == null || valueType == null)
					throw "Map key/value types were not resolved";
				if (RuntimeType.mapName(keyType, valueType) == null)
					fail("E1016", "This map key/value type has no compiler-owned runtime ABI", span);
				new TypedExpression(TMapLiteral(typedEntries), TMap(keyType, valueType), span);
			case ArrayComprehension(keyName, valueName, iterable, predicate, value, span):
				var typedIterable = typeExpression(iterable, scope),
					originalIterable = typedIterable,
					loopScope = new Scope(scope),
					keyType:Null<CompilerType> = null;
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
						keyType = valueName == null ? mapValue : key;
						if (valueName == null) typedIterable = new TypedExpression(TCollectionCall(typedIterable, "values", []), TArray(mapValue), span);
					default:
						fail("E1014", "Array comprehension iterable must be an Array or Map", span);
				}
				if (keyType == null)
					throw "Array comprehension item type was not resolved";
				loopScope.define(keyName, keyType, span);
				if (valueName != null)
					switch originalIterable.type {
						case TMap(_, mapValue): loopScope.define(valueName, mapValue, span);
						default:
					}
				var typedCondition = predicate == null ? null : typeExpression(predicate, loopScope, TBool);
				if (typedCondition != null && typedCondition.type != TBool)
					fail("E1004", "Array comprehension condition must be Bool", span);
				var expectedElement = arrayElementExpectation(expectedType),
					typedValue = typeExpression(value, loopScope, expectedElement),
					elementType = expectedElement == null ? typedValue.type : expectedElement;
				typedValue = coerce(typedValue, elementType, "array comprehension value", "E1003");
				new TypedExpression(TArrayComprehension(loopScope.requireId(keyName), valueName == null ? null : loopScope.requireId(valueName),
					valueName == null ? typedIterable : originalIterable, typedCondition, typedValue),
					TArray(elementType), span);
			case MapComprehension(keyName, valueName, iterable, predicate, key, value, span):
				var typedIterable = typeExpression(iterable, scope),
					originalIterable = typedIterable,
					loopScope = new Scope(scope),
					itemType:Null<CompilerType> = null;
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
						itemType = valueName == null ? mapValue : mapKey;
						if (valueName == null) typedIterable = new TypedExpression(TCollectionCall(typedIterable, "values", []), TArray(mapValue), span);
					default:
						fail("E1014", "Map comprehension iterable must be an Array or Map", span);
				}
				if (itemType == null)
					throw "Map comprehension item type was not resolved";
				loopScope.define(keyName, itemType, span);
				if (valueName != null)
					switch originalIterable.type {
						case TMap(_, mapValue): loopScope.define(valueName, mapValue, span);
						default:
					}
				var typedCondition = predicate == null ? null : typeExpression(predicate, loopScope, TBool);
				if (typedCondition != null && typedCondition.type != TBool)
					fail("E1004", "Map comprehension condition must be Bool", span);
				var expected = mapExpectation(expectedType),
					typedKey = typeExpression(key, loopScope, expected == null ? null : expected.key),
					typedValue = typeExpression(value, loopScope, expected == null ? null : expected.value),
					resultKey = expected == null ? typedKey.type : expected.key,
					resultValue = expected == null ? typedValue.type : expected.value;
				typedKey = coerce(typedKey, resultKey, "map comprehension key", "E1003");
				typedValue = coerce(typedValue, resultValue, "map comprehension value", "E1003");
				if (RuntimeType.mapName(resultKey, resultValue) == null)
					fail("E1016", "This map key/value type has no compiler-owned runtime ABI", span);
				new TypedExpression(TMapComprehension(loopScope.requireId(keyName), valueName == null ? null : loopScope.requireId(valueName),
					valueName == null ? typedIterable : originalIterable, typedCondition, typedKey, typedValue),
					TMap(resultKey, resultValue), span);
			case Range(start, rangeEnd, span):
				var typedStart = typeExpression(start, scope, TInt),
					typedEnd = typeExpression(rangeEnd, scope, TInt);
				if (typedStart.type != TInt || typedEnd.type != TInt)
					fail("E1014", "Range bounds must be Int values", span);
				new TypedExpression(TRange(typedStart, typedEnd), TRange, span);
			case NewGeneric(typeName, typeArguments, arguments, span):
				if (declarations.abstracts.exists(typeName))
					return typeAbstractConstruction(typeName, typeArguments, arguments, span, scope);
				if (!classDecls.exists(typeName) || interfaceDecls.exists(typeName))
					fail("E1007", 'Unknown class "$typeName"', span);
				var valueType = declarations.resolve(AppliedType(typeName, typeArguments), span),
					substitutions = nominalSubstitutions(valueType),
					constructorName = typeName + ".new",
					hasConstructor = signatures.exists(constructorName),
					implicitConstructor = !hasConstructor && [
						for (field in classDecls.get(typeName).fields)
							if (!field.isStatic && field.initializer != null) field
					].length > 0;
				if (!hasConstructor && arguments.length != 0)
					fail("E1008", 'Constructor "$typeName" expects 0 arguments, got ${arguments.length}', span);
				var semanticArguments = hasConstructor ? typeDeclaredCallArguments(arguments, requiredMapValue(signatures, constructorName).arguments, scope,
					constructorName, span, substitutions) : [];
				var typed = [for (argument in semanticArguments) abiBoundaryCast(argument, TDynamic)];
				new TypedExpression(TNew(typeName, typed, hasConstructor || implicitConstructor), valueType, span);
			case New(typeName, arguments, span):
				if (declarations.abstracts.exists(typeName))
					return typeAbstractConstruction(typeName, [], arguments, span, scope);
				if ((!classDecls.exists(typeName) && !PlatformAbi.isType(typeName)) || interfaceDecls.exists(typeName))
					fail("E1007", 'Unknown class "$typeName"', span);
				if (classDecls.exists(typeName) && classDecls.get(typeName).typeParameters.length > 0)
					return typeInferredClassConstruction(typeName, arguments, span, scope, expectedType);
				var constructorName = typeName + ".new",
					hasConstructor = signatures.exists(constructorName),
					implicitConstructor = !hasConstructor && classDecls.exists(typeName) && [
						for (field in classDecls.get(typeName).fields)
							if (!field.isStatic && field.initializer != null) field
					].length > 0;
				var expected = hasConstructor ? [
					for (argument in requiredMapValue(signatures, constructorName).arguments)
						argumentType(argument)
				] : PlatformAbi.constructorArguments(typeName), resolvedExpected:Array<CompilerType> = [];
				if (expected != null)
					resolvedExpected = expected;
				if (!hasConstructor && arguments.length != resolvedExpected.length)
					fail("E1008", 'Constructor "$typeName" expects ${resolvedExpected.length} arguments, got ${arguments.length}', span);
				var typed = hasConstructor ? typeDeclaredCallArguments(arguments, requiredMapValue(signatures, constructorName).arguments, scope,
					constructorName, span) : typeCallArguments(arguments, resolvedExpected, scope, constructorName);
				var nativeConstructor = PlatformAbi.constructorNative(typeName),
					valueType = PlatformAbi.valueType(typeName);
				nativeConstructor == null ? new TypedExpression(TNew(typeName, typed, hasConstructor || implicitConstructor), valueType,
					span) : new TypedExpression(TCall(nativeConstructor, typed), valueType, span);
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
				var typedArray = unwrapNullable(typeExpression(array, scope)),
					typedIndex = typeExpression(offset, scope);
				switch typedArray.type {
					case TMap(key, value):
						var typedKey = coerce(typedIndex, key, "map key", "E1002");
						var entryPath = FlowAnalysis.mapEntryPath(typedArray, typedKey),
							refined = entryPath == null ? null : scope.resolveExpression(entryPath);
						new TypedExpression(TMapGet(typedArray, typedKey), refined == null ? nullableMapValue(value) : refined, span);
					default:
						if (typedIndex.type == TNever)
							typedIndex = coerce(typedIndex, TInt, "array index", "E1014");
						if (typedIndex.type != TInt)
							fail("E1014", "Array index must be Int", typedIndex.span);
						var element = arrayElementType(typedArray.type, span);
						new TypedExpression(TIndex(typedArray, typedIndex), element, span);
				}
			case Call(name, arguments, span):
				if (name == "super")
					return typeSuperCall(arguments, span, scope);
				if (name == "Reflect.compare") {
					if (arguments.length != 2)
						fail("E1008", 'Function "Reflect.compare" expects 2 arguments, got ${arguments.length}', span);
					var left = typeExpression(arguments[0], scope),
						right = typeExpression(arguments[1], scope, left.type);
					if (sameType(left.type, TString) && sameType(right.type, TString))
						return new TypedExpression(TCall("__string_compare_full", [left, right]), TInt, span);
				}
				if (name == "haxe.io.Bytes.ofString") {
					if (arguments.length < 1 || arguments.length > 2)
						fail("E1008", 'Function "haxe.io.Bytes.ofString" expects 1 or 2 arguments, got ${arguments.length}', span);
					var value = coerce(typeExpression(arguments[0], scope, TString), TString, "byte string", "E1002");
					return new TypedExpression(TCall("haxe.io.Bytes.ofString", [value]), TBytes, span);
				}
				if (name == "Std.int") {
					if (arguments.length != 1)
						fail("E1008", 'Function "Std.int" expects 1 argument, got ${arguments.length}', span);
					var value = typeExpression(arguments[0], scope);
					return switch value.type {
						case TInt: value;
						case TFloat: new TypedExpression(TCall("__std_int_f64", [value]), TInt, span);
						default:
							fail("E1009", "Std.int expects an Int or Float", value.span);
							new TypedExpression(TIntLiteral(0), TInt, span);
					};
				}
				if (name == "String.__alloc__") {
					if (arguments.length != 2)
						fail("E1008", 'Function "String.__alloc__" expects 2 arguments, got ${arguments.length}', span);
					var bytes = typeExpression(arguments[0], scope);
					switch bytes.type {
						case THlBytes, TAbstract(_, _, THlBytes):
						default: fail("E1009", "String.__alloc__ expects hl.Bytes data", bytes.span);
					}
					bytes = abiBoundaryCast(bytes, THlBytes);
					var length = typeExpression(arguments[1], scope, TInt);
					if (!sameType(length.type, TInt))
						fail("E1009", "String.__alloc__ expects an Int length", length.span);
					return new TypedExpression(TCall("__string_from_bytes", [bytes, length]), TString, span);
				}
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
					for (captured in context.storage.candidateSourceNames())
						scope.invalidate(captured);
					new TypedExpression(TClosureCall(typeExpression(Variable(name, span), scope), typed), functionType.result, span);
				} else {
					if (name.indexOf(".") < 0) {
						var thisType = scope.resolve("this"),
							fieldType = thisType == null ? null : findFieldType(thisType, name);
						if (fieldType != null) {
							var fieldCallable = typeExpression(Variable(name, span), scope);
							switch fieldCallable.type {
								case TFunction(argumentTypes, result):
									if (arguments.length != argumentTypes.length)
										fail("E1008", 'Function field "$name" expects ${argumentTypes.length} arguments, got ${arguments.length}', span);
									var typed = [
										for (index in 0...arguments.length)
											typeExpression(arguments[index], scope, argumentTypes[index])
									];
									typed = coerceArguments(typed, argumentTypes, name);
									return new TypedExpression(TClosureCall(fieldCallable, typed), result, span);
								default: fail("E1007", 'Cannot call non-function field "$name"', span);
							}
						}
						var implicitMethod = lexicalMethod(name);
						if (implicitMethod != null) {
							var methodKey = implicitMethod.owner + "." + name,
								method = signatures.get(methodKey);
							if (method == null)
								fail("E1007", 'Missing signature for method "$methodKey"', span);
							if (isGeneric(method)) {
								if (!implicitMethod.isStatic)
									fail("E1007", "Generic instance methods are not supported yet", span);
								var preset:Map<String, CompilerType> = [],
									parameters = functionTypeParameters(method),
									hasLambda = false;
								for (argument in arguments)
									switch argument {
										case Lambda(_, _, _): hasLambda = true;
										default:
									}
								if (expectedType != null)
									inferTypeParameters(method.result, expectedType, parameters, preset, span);
								var contextual = hasLambda || expectedType != null,
									typingSubstitutions = copyMap(preset);
								if (contextual)
									for (parameter in parameters)
										if (!typingSubstitutions.exists(parameter))
											typingSubstitutions.set(parameter, TDynamic);
								var genericArguments = contextual ? [
									for (index in 0...arguments.length)
										typeExpression(arguments[index], scope,
											declarations.resolve(method.arguments[index].type, method.arguments[index].span, typingSubstitutions), true)
								] : [for (argument in arguments) typeExpression(argument, scope)];
								var specialized = specializeGeneric(methodKey, method, genericArguments, span, scope, implicitMethod.owner, true, preset);
								return specialized;
							}
							var typed = typeDeclaredCallArguments(arguments, method.arguments, scope, methodKey, span);
							if (implicitMethod.isStatic)
								return applyCallEffect(new TypedExpression(TCall(methodKey, typed), lowerType(method.result), span), methodKey);
							var thisType = scope.resolve("this");
							if (thisType == null)
								fail("E1007", 'Instance method "$methodKey" requires an object', span);
							var receiver = typeExpression(Variable("this", span), scope);
							return applyCallEffect(new TypedExpression(TMethodCall(receiver, methodKey, typed), lowerType(method.result), span), methodKey);
						}
					}
					var parts = splitPath(name),
						receiverName:Null<String> = null,
						receiver:Null<TypedExpression> = null,
						methodName:Null<String> = null;
					if (parts.length >= 2) {
						methodName = parts[parts.length - 1];
						if (!signatures.exists(name)) {
							var resolvedReceiverName = parts[0];
							receiverName = resolvedReceiverName;
							receiver = resolveReceiver(resolvedReceiverName, span, scope);
						}
					}
					if (receiver != null && parts.length > 2)
						for (index in 1...parts.length - 1)
							receiver = typedMemberWithFlow(receiver, parts[index], span, scope);
					if (receiver != null)
						receiver = unwrapNullable(receiver);
					var receiverType = receiver == null ? null : receiver.type;
					var enumCase = enumCaseInfo(name);
					if (enumCase == null && name.indexOf(".") < 0) {
						var expectedEnum = enumName(expectedType);
						if (expectedEnum != null)
							enumCase = enumCaseInfo(expectedEnum + "." + name);
					}
					if (enumCase != null) {
						var expected = [
							for (param in enumCase.params)
								enumParameterType(enumCase.typeParameters, param, expectedType)
						];
						var required = requiredEnumParameters(enumCase.params);
						if (arguments.length < required || arguments.length > expected.length)
							fail("E1008", 'Enum constructor "$name" expects $required to ${expected.length} arguments, got ${arguments.length}', span);
						var typedArguments = [for (i in 0...arguments.length) typeExpression(arguments[i], scope, expected[i])];
						while (typedArguments.length < expected.length)
							typedArguments.push(new TypedExpression(TNullLiteral, TNull, span));
						typedArguments = coerceArguments(typedArguments, expected, name);
						for (index in 0...typedArguments.length)
							typedArguments[index] = abiBoundaryCast(typedArguments[index],
								enumStorageParameterType(enumCase.typeParameters, enumCase.params[index]));
						var resultType:CompilerType = TInstance(NominalKind.Enum, enumCase.enumName, []);
						var resolvedExpected = expectedType;
						if (resolvedExpected != null)
							switch resolvedExpected {
								case TInstance(Enum, expectedName, _) if (expectedName == enumCase.enumName): resultType = resolvedExpected;
								case TNullable(element):
									switch element {
										case TInstance(Enum, expectedName, _) if (expectedName == enumCase.enumName): resultType = resolvedExpected;
										default:
									}
								default:
							}
						return new TypedExpression(TEnumConstruct(enumCase.enumName, enumCase.index, typedArguments), resultType, span);
					}
					if (receiverType != null && methodName != null) {
						var resolvedReceiver = requiredExpression(receiver),
							resolvedMethodName = requiredString(methodName);
						var stringCall = typeStringMethod(resolvedReceiver, resolvedMethodName, arguments, span, scope);
						if (stringCall != null)
							return stringCall;
						if (isMap(receiverType))
							return typeMapMethod(resolvedReceiver, resolvedMethodName, arguments, span, scope);
						if (isArray(receiverType))
							return typeArrayMethod(resolvedReceiver, resolvedMethodName, arguments, span, scope);
						var platformMethod = PlatformAbi.method(receiverType, resolvedMethodName);
						if (platformMethod != null) {
							var typed = typeCallArguments(arguments, platformMethod.arguments, scope, resolvedMethodName),
								callArguments:Array<TypedExpression> = [resolvedReceiver];
							for (argument in typed)
								callArguments.push(argument);
							return new TypedExpression(TCall(platformMethod.nativeName, callArguments), platformMethod.result, span);
						}
						var abstractCall = typeAbstractMethodCall(resolvedReceiver, resolvedMethodName, arguments, span, scope);
						if (abstractCall != null)
							return abstractCall;
						var fieldCall = typeFunctionFieldCall(resolvedReceiver, resolvedMethodName, arguments, span, scope);
						if (fieldCall != null)
							return fieldCall;
						var className = switch receiverType {
							case TInstance(Class, value, _), TInstance(Interface, value, _): value;
							default: null;
						};
						if (className == null)
							fail("E1007", 'Cannot call method on non-object "$receiverName"', span);
						var methodInfoResult = findMethod(className, resolvedMethodName);
						if (methodInfoResult == null || methodInfoResult.isStatic)
							fail("E1007", 'Unknown instance method "$className.$methodName"', span);
						var methodKey = methodInfoResult.owner + "." + resolvedMethodName;
						var method = signatures.get(methodKey);
						if (method == null)
							fail("E1007", 'Missing signature for method "$methodKey"', span);
						if (isGeneric(method)) {
							var preset:Map<String, CompilerType> = [],
								parameters = functionTypeParameters(method),
								hasLambda = false;
							for (argument in arguments)
								switch argument {
									case Lambda(_, _, _): hasLambda = true;
									default:
								}
							if (expectedType != null)
								inferTypeParameters(method.result, expectedType, parameters, preset, span);
							var contextual = hasLambda || expectedType != null,
								typingSubstitutions = copyMap(preset);
							if (contextual)
								for (parameter in parameters)
									if (!typingSubstitutions.exists(parameter))
										typingSubstitutions.set(parameter, TDynamic);
							var genericArguments = contextual ? [
								for (index in 0...arguments.length)
									typeExpression(arguments[index], scope,
										declarations.resolve(method.arguments[index].type, method.arguments[index].span, typingSubstitutions), true)
							] : [for (argument in arguments) typeExpression(argument, scope)];
							var specialized = specializeGeneric(methodKey, method, genericArguments, span, scope, methodInfoResult.owner,
								methodInfoResult.isStatic, preset, methodInfoResult.isStatic ? null : resolvedReceiver);
							return specialized;
						}
						var methodOwnerType = projectNominal(receiverType, methodInfoResult.owner),
							substitutions = nominalSubstitutions(methodOwnerType),
							typed = typeDeclaredCallArguments(arguments, method.arguments, scope, methodKey, span, substitutions),
							semanticResult = declarations.resolve(method.result, method.span, substitutions),
							physicalResult = isGenericNominal(methodOwnerType) ? TDynamic : semanticResult,
							call = new TypedExpression(TMethodCall(resolvedReceiver, methodKey, typed), physicalResult, span);
						applyCallEffect(abiBoundaryCast(call, semanticResult), methodKey);
					} else {
						var hasSignature = signatures.exists(name);
						if (hasSignature && isGeneric(requiredMapValue(signatures, name))) {
							var signature = requiredMapValue(signatures, name),
								infoOwner:Null<String> = null,
								infoStatic = true;
							if (methodInfo.exists(name)) {
								var resolvedInfo = requiredMapValue(methodInfo, name);
								infoOwner = resolvedInfo.owner;
								infoStatic = resolvedInfo.isStatic;
							}
							var typed = [for (argument in arguments) typeExpression(argument, scope)],
								specialized = specializeGeneric(name, signature, typed, span, scope, infoOwner, infoStatic);
							return specialized;
						}
						var expectedArguments:Array<CompilerType> = [],
							result:CompilerType = TVoid;
						if (hasSignature) {
							var signature = requiredMapValue(signatures, name);
							expectedArguments = [for (argument in signature.arguments) argumentType(argument)];
							result = lowerType(signature.result);
						} else if (externals.exists(name)) {
							var external = requiredMapValue(externals, name);
							expectedArguments = external.arguments;
							result = external.result;
						} else
							fail("E1007", 'Unknown function "$name"', span);
						if (!hasSignature && arguments.length != expectedArguments.length)
							fail("E1008", 'Function "$name" expects ${expectedArguments.length} arguments, got ${arguments.length}', span);
						var typed = hasSignature ? typeDeclaredCallArguments(arguments, requiredMapValue(signatures, name).arguments, scope, name,
							span) : typeCallArguments(arguments, expectedArguments, scope, name);
						applyCallEffect(new TypedExpression(TCall(name, typed), result, span), name);
					}
				}
			case MethodCall(object, name, arguments, span): typeMethodCall(object, name, arguments, span, scope, expectedType);
		}

	function typeMember(object:AstExpression, name:String, span:SourceSpan, scope:Scope):TypedExpression {
		return typedMemberWithFlow(typeExpression(object, scope), name, span, scope);
	}

	function typedMemberWithFlow(object:TypedExpression, name:String, span:SourceSpan, scope:Scope):TypedExpression {
		var member = typedMember(object, name, span),
			path = FlowAnalysis.accessPath(member);
		if (path == null)
			return member;
		var refined = scope.resolveExpression(path);
		return refined == null || sameType(member.type, refined) ? member : new TypedExpression(TCast(member), refined, member.span);
	}

	function typeAbstractConstruction(name:String, typeArguments:Array<AstType>, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope):TypedExpression {
		var decl = requiredMapValue(declarations.abstracts, name),
			valueType = typeArguments.length == 0 ? declarations.resolve(NamedType(name), span) : declarations.resolve(AppliedType(name, typeArguments), span),
			constructorName = name + ".new",
			constructor = signatures.get(constructorName);
		if (constructor == null)
			fail("E1007", 'Abstract "$name" has no constructor', span);
		if (decl.isExtern == true) {
			var typed = typeDeclaredCallArguments(arguments, constructor.arguments, scope, constructorName, span);
			return new TypedExpression(TCall(constructorName, typed), valueType, span);
		}
		var substitutions:Map<String, CompilerType> = [],
			representation:CompilerType = TVoid;
		switch valueType {
			case TAbstract(_, appliedArguments, underlying):
				representation = underlying;
				for (index in 0...decl.typeParameters.length)
					substitutions.set(decl.typeParameters[index], appliedArguments[index]);
			default:
		}
		var resolvedConstructor = Typer.requiredFunction(constructor),
			normalized = AbstractConstructorNormalizer.normalize(resolvedConstructor, decl.underlying),
			typedArguments = [for (argument in arguments) typeExpression(argument, scope)],
			constructed:TypedExpression;
		try {
			constructed = specializeGeneric(constructorName, normalized, typedArguments, span, scope, name, true, substitutions);
		} catch (error:CompileError) {
			var message = error.diagnostic.message;
			if (StringTools.startsWith(message, 'Type mismatch for local "' + AbstractConstructorNormalizer.RESULT_PREFIX))
				fail("E1003", 'Type mismatch for abstract constructor "$constructorName"', error.diagnostic.span);
			if (StringTools.startsWith(message, 'Local "' + AbstractConstructorNormalizer.RESULT_PREFIX)
				&& message.indexOf("may be used before assignment") >= 0)
				fail("E1023", 'Abstract constructor "$constructorName" does not initialize this on every path', error.diagnostic.span);
			throw error;
		}
		return new TypedExpression(TAbiCast(coerce(constructed, representation, 'abstract constructor "$constructorName"', "E1003")), valueType, span);
	}

	function applyCallEffect(call:TypedExpression, name:String):TypedExpression
		return noReturnFunctions.exists(name) ? new TypedExpression(TNoReturn(call), TNever, call.span) : call;

	function typeSuperCall(arguments:Array<AstExpression>, span:SourceSpan, scope:Scope):TypedExpression {
		var owner = context.lexicalOwner, baseType:Null<AstType> = null;
		if (owner != null && classDecls.exists(owner))
			baseType = requiredMapValue(classDecls, owner).base;
		if (baseType == null)
			fail("E1007", "super() requires a base-class constructor", span);
		var baseInstance = declarations.resolve(baseType, span, context.typeSubstitutions),
			resolvedBase = nominalName(baseInstance),
			substitutions = nominalSubstitutions(baseInstance),
			constructorName = resolvedBase + ".new",
			hasConstructor = signatures.exists(constructorName),
			expected = PlatformAbi.constructorArguments(resolvedBase),
			resolvedExpected:Array<CompilerType> = [];
		if (expected != null)
			resolvedExpected = expected;
		if (!hasConstructor && arguments.length != resolvedExpected.length)
			fail("E1008", 'Constructor "$resolvedBase" expects ${resolvedExpected.length} arguments, got ${arguments.length}', span);
		var semanticArguments = hasConstructor ? typeDeclaredCallArguments(arguments, requiredMapValue(signatures, constructorName).arguments, scope,
			constructorName, span, substitutions) : typeCallArguments(arguments, resolvedExpected, scope, constructorName),
			physicalArguments = isGenericNominal(baseInstance) ? [for (argument in semanticArguments) abiBoundaryCast(argument, TDynamic)] : semanticArguments;
		return new TypedExpression(TSuperCall(resolvedBase, physicalArguments), TVoid, span);
	}

	function specializeGeneric(baseName:String, fn:AstFunction, arguments:Array<TypedExpression>, span:SourceSpan, scope:Scope, owner:Null<String>,
			isStatic:Bool, ?presetSubstitutions:Map<String, CompilerType>, ?receiver:TypedExpression):TypedExpression {
		var required = fn.arguments.length;
		while (required > 0 && fn.arguments[required - 1].optional)
			required--;
		if (arguments.length < required || arguments.length > fn.arguments.length) {
			var expected = required == fn.arguments.length ? '$required' : '$required to ${fn.arguments.length}';
			fail("E1008", 'Function "$baseName" expects $expected arguments, got ${arguments.length}', span);
		}
		var substitutions:Map<String, CompilerType> = presetSubstitutions == null ? [] : [
			for (parameter => type in presetSubstitutions)
				parameter => type
		],
			parameters = functionTypeParameters(fn);
		for (i in 0...arguments.length)
			inferTypeParameters(fn.arguments[i].type, arguments[i].type, parameters, substitutions, arguments[i].span);
		for (parameter in parameters)
			if (!substitutions.exists(parameter))
				fail("E1003", 'Cannot infer generic type parameter "$parameter" for "$baseName"', span);
		var constraints = fn.typeConstraints;
		if (constraints != null)
			for (constraint in constraints) {
				var actual = requiredMapValue(substitutions, constraint.parameter),
					expected = declarations.resolve(constraint.type, constraint.span, substitutions);
				if (!isAssignable(actual, expected))
					fail("E1003", 'Type argument for "${constraint.parameter}" does not satisfy constraint "${SemanticSignature.type(expected)}"', span);
			}
		var semanticExpected = [
			for (argument in fn.arguments)
				argumentType(argument, substitutions)
		];
		for (index in arguments.length...fn.arguments.length) {
			var parameter = fn.arguments[index],
				defaultValue = parameter.defaultValue,
				expected = semanticExpected[index];
			if (isPosInfosParameter(parameter))
				arguments.push(coerce(typeExpression(posInfosExpression(span), scope, expected), expected, 'position argument ${index + 1} to "$baseName"'));
			else if (defaultValue == null)
				arguments.push(coerce(new TypedExpression(TNullLiteral, TNull, span), expected, 'default argument ${index + 1} to "$baseName"'));
			else
				arguments.push(coerce(typeDefaultExpression(defaultValue, expected, baseName), expected, 'default argument ${index + 1} to "$baseName"'));
		}
		var semanticArguments = coerceArguments(arguments, semanticExpected, baseName),
			result = declarations.resolve(fn.result, fn.span, substitutions),
			representationSubstitutions:Map<String, CompilerType> = [];
		var specializationPolicies:Array<String> = [];
		for (parameter in parameters) {
			var decision = GenericSpecializationPolicy.decide(fn, parameter, requiredMapValue(substitutions, parameter));
			representationSubstitutions.set(parameter, decision.representation);
			specializationPolicies.push(decision.policy);
		}
		var representationExpected = [
			for (argument in fn.arguments)
				argumentType(argument, representationSubstitutions)
		], typed = [
			for (index in 0...semanticArguments.length)
				abiBoundaryCast(semanticArguments[index], representationExpected[index])
			], representationResult = declarations.resolve(fn.result, fn.span, representationSubstitutions), representationArguments = [
			for (parameter in parameters)
				requiredMapValue(representationSubstitutions, parameter)
			], specialization = genericSpecializations.request(baseName, representationArguments, specializationPolicies);
		var representationReceiver:Null<CompilerType> = null;
		if (receiver != null)
			representationReceiver = declarations.abstracts.exists(requiredString(owner)) ? abstractReceiverType(requiredString(owner),
				representationSubstitutions) : receiver.type;
		if (!emittedGenericBodies.exists(specialization.name)) {
			emittedGenericBodies.set(specialization.name, true);
			closureConversion.addFunction(typeFunction(fn, owner, receiver == null ? isStatic : true, representationSubstitutions, specialization.name,
				representationReceiver));
		}
		if (receiver != null) {
			var receiverType = representationReceiver;
			if (receiverType == null)
				throw "Generic receiver representation was not resolved";
			typed.unshift(abiBoundaryCast(receiver, receiverType));
		}
		var call = new TypedExpression(TCall(specialization.name, typed), representationResult, span);
		return sameType(representationResult, result) ? call : abiBoundaryCast(call, result);
	}

	function abstractReceiverType(name:String, substitutions:Map<String, CompilerType>):CompilerType {
		var decl = requiredMapValue(declarations.abstracts, name), arguments = [
			for (parameter in decl.typeParameters)
				requiredMapValue(substitutions, parameter)
		], representation = declarations.resolve(decl.underlying, decl.span, substitutions);
		return TAbstract(name, arguments, representation);
	}

	function inferTypeParameters(pattern:AstType, actual:CompilerType, parameters:Array<String>, substitutions:Map<String, CompilerType>, span:SourceSpan):Void
		switch pattern {
			case NamedType(name) if (parameters.indexOf(name) >= 0):
				if (substitutions.exists(name)) {
					var previous = requiredMapValue(substitutions, name);
					if (previous == TDynamic)
						substitutions.set(name, actual);
					else if (actual != TDynamic && !sameType(previous, actual)) {
						if (isAssignable(actual, previous))
							substitutions.set(name, actual);
						else if (!isAssignable(previous, actual))
							fail("E1003", 'Conflicting types inferred for generic parameter "$name"', span);
					}
				} else
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
			case AppliedType(name, patternArguments):
				switch actual {
					case TInstance(_, actualName, actualArguments) if (actualName == name
						&& patternArguments.length == actualArguments.length):
						for (index in 0...patternArguments.length)
							inferTypeParameters(patternArguments[index], actualArguments[index], parameters, substitutions, span);
					case TAbstract(actualName, actualArguments, _) if (actualName == name
						&& patternArguments.length == actualArguments.length):
						for (index in 0...patternArguments.length)
							inferTypeParameters(patternArguments[index], actualArguments[index], parameters, substitutions, span);
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
		switch typedObject.type {
			case TNullable(_):
				fail("E1005", 'Field "$name" requires an object', span);
			default:
		}
		switch typedObject.expression {
			case TClassRef(className):
				if (enumAbstractDecls.exists(className)) {
					var abstractDecl = requiredMapValue(enumAbstractDecls, className);
					for (value in abstractDecl.values)
						if (value.name == name)
							return typeExpression(value.value, new Scope(), lowerType(abstractDecl.underlying));
				}
				var staticField = findStaticField(className, name, span);
				return new TypedExpression(TStaticField(staticField.owner, name), staticField.type, span);
			default:
		}
		if (name == "length" && isArray(typedObject.type))
			return new TypedExpression(TArrayLength(typedObject), TInt, span);
		if (name == "length" && sameType(typedObject.type, TString))
			return new TypedExpression(TStringLength(typedObject), TInt, span);
		if (name == "code")
			switch typedObject.expression {
				case TStringLiteral(value) if (value.length == 1):
					return new TypedExpression(TIntLiteral(value.charCodeAt(0)), TInt, span);
				case TStringLiteral(_):
					fail("E1007", "String literal .code requires exactly one character", span);
				default:
			}
		var platformField = PlatformAbi.field(typedObject.type, name);
		if (platformField != null)
			return new TypedExpression(TCall(platformField.get, [typedObject]), platformField.type, span);
		var getter = instancePropertyAccessor(typedObject.type, name, true);
		if (getter != null) {
			var method = requiredMapValue(signatures, getter);
			return new TypedExpression(TMethodCall(typedObject, getter, []),
				declarations.resolve(method.result, method.span, nominalSubstitutions(typedObject.type)), span);
		}
		var owner = switch typedObject.type {
			case TInstance(Class, className, _), TInstance(Interface, className, _): className;
			default: null;
		};
		if (owner != null) {
			var methodInfo = findMethod(owner, name);
			if (methodInfo != null && !methodInfo.isStatic) {
				var methodKey = methodInfo.owner + "." + name,
					method = requiredMapValue(signatures, methodKey);
				if (isGeneric(method))
					fail("E1007", "Generic instance method values are not supported yet", span);
				var substitutions = nominalSubstitutions(projectNominal(typedObject.type, methodInfo.owner)),
					arguments = [for (argument in method.arguments) argumentType(argument, substitutions)],
					result = declarations.resolve(method.result, method.span, substitutions);
				return new TypedExpression(TMethodRef(typedObject, methodKey), TFunction(arguments, result), span);
			}
		}
		var semanticType = fieldType(typedObject.type, name, span),
			physicalType = fieldRepresentationType(typedObject.type, name, span);
		return abiBoundaryCast(new TypedExpression(TField(typedObject, name), physicalType, span), semanticType);
	}

	static function unwrapNullable(value:TypedExpression):TypedExpression
		return switch value.type {
			case TNullable(element): new TypedExpression(value.expression, element, value.span);
			default: value;
		};

	function instancePropertyAccessor(type:CompilerType, name:String, read:Bool):Null<String>
		return switch type {
			case TInstance(Class, className, _) if (classDecls.exists(className)):
				var declaration = requiredMapValue(classDecls, className),
					accessor:Null<String> = null;
				for (field in declaration.fields)
					if (field.name == name && !field.isStatic) {
						var usesAccessor = read ? field.readAccess == GetAccess : field.writeAccess == SetAccess;
						if (usesAccessor)
							accessor = className + "." + (read ? "get_" : "set_") + name;
					}
				if (accessor != null) accessor; else if (declaration.base != null) instancePropertyAccessor(declarations.resolve(declaration.base,
					declaration.span, nominalSubstitutions(type)), name, read); else null;
			default: null;
		};

	function fieldRepresentationType(type:CompilerType, name:String, span:SourceSpan):CompilerType
		return switch type {
			case TInstance(NominalKind.Class, className, _) if (classDecls.exists(className)):
				var declaration = requiredMapValue(classDecls, className),
					substitutions:Map<String, CompilerType> = [];
				for (parameter in declaration.typeParameters)
					substitutions.set(parameter, TDynamic);
				var result:Null<CompilerType> = null;
				for (field in declaration.fields)
					if (field.name == name && !field.isStatic)
						result = declarations.resolve(declarations.resolvedFieldType(className, field), field.span, substitutions);
				if (result != null) result; else if (declaration.base != null) fieldRepresentationType(declarations.resolve(declaration.base,
					declaration.span, substitutions), name, span); else fieldType(type, name, span);
			default: fieldType(type, name, span);
		};

	function isGenericNominal(type:CompilerType):Bool
		return switch type {
			case TInstance(Class, _, arguments), TInstance(Interface, _, arguments): arguments.length > 0;
			default: false;
		};

	function findStaticField(className:String, name:String, span:SourceSpan):{owner:String, type:CompilerType} {
		var result = findStaticFieldNullable(className, name);
		if (result != null)
			return result;
		throw new CompileError(new Diagnostic("E1005", 'Unknown static field "$className.$name"', span));
	}

	function findStaticFieldNullable(className:String, name:String):Null<{owner:String, type:CompilerType}> {
		if (!classDecls.exists(className))
			return null;
		var classDecl = requiredMapValue(classDecls, className);
		for (field in classDecl.fields)
			if (field.name == name && field.isStatic)
				return {owner: className, type: lowerType(declarations.resolvedFieldType(className, field))};
		var base = classDecl.base;
		return base == null ? null : findStaticFieldNullable(inheritanceName(base), name);
	}

	function typeMethodCall(object:AstExpression, name:String, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope,
			?expectedType:CompilerType):TypedExpression {
		var receiver = unwrapNullable(typeExpression(object, scope));
		var platformMethod = PlatformAbi.method(receiver.type, name);
		if (platformMethod != null) {
			var typed = typeCallArguments(arguments, platformMethod.arguments, scope, name);
			return new TypedExpression(TCall(platformMethod.nativeName, [receiver].concat(typed)), platformMethod.result, span);
		}
		var stringCall = typeStringMethod(receiver, name, arguments, span, scope);
		if (stringCall != null)
			return stringCall;
		if (isMap(receiver.type))
			return typeMapMethod(receiver, name, arguments, span, scope);
		if (isArray(receiver.type))
			return typeArrayMethod(receiver, name, arguments, span, scope);
		var abstractCall = typeAbstractMethodCall(receiver, name, arguments, span, scope);
		if (abstractCall != null)
			return abstractCall;
		var fieldCall = typeFunctionFieldCall(receiver, name, arguments, span, scope);
		if (fieldCall != null)
			return fieldCall;
		var className = switch receiver.type {
			case TInstance(Class, value, _), TInstance(Interface, value, _): value;
			default: null;
		};
		if (className == null)
			fail("E1007", 'Cannot call method on non-object "$name"', span);
		var methodInfoResult = findMethod(className, name);
		if (methodInfoResult == null || methodInfoResult.isStatic)
			fail("E1007", 'Unknown instance method "$className.$name"', span);
		var methodOwnerType = projectNominal(receiver.type, methodInfoResult.owner),
			substitutions = nominalSubstitutions(methodOwnerType),
			methodKey = methodInfoResult.owner + "." + name,
			method = signatures.get(methodKey);
		if (method == null)
			fail("E1007", 'Missing signature for method "$methodKey"', span);
		if (isGeneric(method)) {
			var preset = copyMap(substitutions),
				parameters = functionTypeParameters(method);
			if (expectedType != null)
				inferTypeParameters(method.result, expectedType, parameters, preset, span);
			var typingSubstitutions = copyMap(preset);
			for (parameter in parameters)
				if (!typingSubstitutions.exists(parameter))
					typingSubstitutions.set(parameter, TDynamic);
			var genericArguments = [
				for (index in 0...arguments.length)
					typeExpression(arguments[index], scope,
						declarations.resolve(method.arguments[index].type, method.arguments[index].span, typingSubstitutions), true)
			];
			return specializeGeneric(methodKey, method, genericArguments, span, scope, methodInfoResult.owner, false, preset, receiver);
		}
		var typed = typeDeclaredCallArguments(arguments, method.arguments, scope, methodKey, span, substitutions);
		var semanticResult = declarations.resolve(method.result, method.span, substitutions),
			physicalResult = isGenericNominal(methodOwnerType) ? TDynamic : semanticResult,
			call = new TypedExpression(TMethodCall(receiver, methodKey, typed), physicalResult, span);
		return applyCallEffect(abiBoundaryCast(call, semanticResult), methodKey);
	}

	function typeFunctionFieldCall(receiver:TypedExpression, name:String, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope):Null<TypedExpression> {
		var callableFieldType = findFieldType(receiver.type, name);
		if (callableFieldType == null)
			return null;
		return switch callableFieldType {
			case TFunction(argumentTypes, result):
				if (arguments.length != argumentTypes.length)
					fail("E1008", 'Function field "$name" expects ${argumentTypes.length} arguments, got ${arguments.length}', span);
				var typed = [
					for (index in 0...arguments.length)
						typeExpression(arguments[index], scope, argumentTypes[index])
				];
				typed = coerceArguments(typed, argumentTypes, name);
				new TypedExpression(TClosureCall(typedMember(receiver, name, span), typed), result, span);
			default:
				fail("E1007", 'Cannot call non-function field "$name"', span);
				null;
		};
	}

	function typeAbstractMethodCall(receiver:TypedExpression, name:String, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope):Null<TypedExpression> {
		var abstractName:String, typeArguments:Array<CompilerType>;
		switch receiver.type {
			case TAbstract(name, arguments, _):
				abstractName = name;
				typeArguments = arguments;
			default:
				return null;
		}
		var decl = requiredMapValue(declarations.abstracts, abstractName),
			method:Null<AstFunction> = null;
		for (candidate in decl.methods)
			if (candidate.name == name && !candidate.isStatic && candidate.name != "new")
				method = candidate;
		if (method == null)
			fail("E1007", 'Unknown abstract method "$abstractName.$name"', span);
		var methodKey = abstractName + "." + name,
			signature = requiredMapValue(signatures, methodKey),
			substitutions:Map<String, CompilerType> = [];
		for (index in 0...decl.typeParameters.length)
			substitutions.set(decl.typeParameters[index], typeArguments[index]);
		if (decl.isExtern == true) {
			var typed = typeDeclaredCallArguments(arguments, signature.arguments, scope, methodKey, span, substitutions),
				callArguments:Array<TypedExpression> = [
					abiBoundaryCast(receiver, declarations.resolve(decl.underlying, decl.span, substitutions))
				];
			for (argument in typed)
				callArguments.push(argument);
			return new TypedExpression(TCall(methodKey, callArguments), declarations.resolve(signature.result, signature.span, substitutions), span);
		}
		var typedArguments = [for (argument in arguments) typeExpression(argument, scope)];
		return specializeGeneric(methodKey, signature, typedArguments, span, scope, abstractName, false, substitutions, receiver);
	}

	function typeStringMethod(receiver:TypedExpression, name:String, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope):Null<TypedExpression> {
		if (!sameType(receiver.type, TString))
			return null;
		if (name == "toLowerCase") {
			if (arguments.length != 0)
				fail("E1008", 'Function "String.toLowerCase" expects no arguments, got ${arguments.length}', span);
			return new TypedExpression(TCall("__string_to_lower_case", [receiver]), TString, span);
		}
		if (name == "indexOf") {
			if (arguments.length < 1 || arguments.length > 2)
				fail("E1008", 'Function "String.indexOf" expects 1 or 2 arguments, got ${arguments.length}', span);
			var needle = typeExpression(arguments[0], scope);
			if (!sameType(needle.type, TString))
				fail("E1009", "String.indexOf expects a String needle", needle.span);
			if (arguments.length == 1)
				return new TypedExpression(TStringIndexOf(receiver, needle), TInt, span);
			var start = typeExpression(arguments[1], scope, TInt);
			if (!sameType(start.type, TInt))
				fail("E1009", "String.indexOf expects an Int start index", start.span);
			return new TypedExpression(TCall("__string_index_of_from", [receiver, needle, start]), TInt, span);
		}
		if (name == "lastIndexOf") {
			if (arguments.length != 1)
				fail("E1008", 'Function "String.lastIndexOf" expects 1 argument, got ${arguments.length}', span);
			var needle = typeExpression(arguments[0], scope, TString);
			if (!sameType(needle.type, TString))
				fail("E1009", "String.lastIndexOf expects a String needle", needle.span);
			return new TypedExpression(TCall("__string_last_index_of", [receiver, needle]), TInt, span);
		}
		if (name == "substring" || name == "substr") {
			if (arguments.length < 1 || arguments.length > 2)
				fail("E1008", 'Function "String.$name" expects 1 or 2 arguments, got ${arguments.length}', span);
			var start = typeExpression(arguments[0], scope),
				end:Null<TypedExpression> = arguments.length == 1 ? null : typeExpression(arguments[1], scope);
			if (!sameType(start.type, TInt) || (end != null && !sameType(end.type, TInt)))
				fail("E1009", "String.$name expects Int bounds", span);
			if (name == "substr" && end != null)
				end = new TypedExpression(TAdd(start, end), TInt, span);
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
		if (name == "split") {
			if (arguments.length != 1)
				fail("E1008", 'Function "String.split" expects one argument, got ${arguments.length}', span);
			var separator = typeExpression(arguments[0], scope, TString);
			if (!sameType(separator.type, TString))
				fail("E1009", "String.split expects a String separator", separator.span);
			return new TypedExpression(TCall("__string_split", [receiver, separator]), TArray(TString), span);
		}
		throw new CompileError(new Diagnostic("E1007", 'Unknown String method "$name"', span));
	}

	function typeArrayMethod(receiver:TypedExpression, name:String, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope):TypedExpression {
		var element = switch receiver.type {
			case TArray(value): value;
			default: throw "Not an array";
		};
		if (RuntimeType.arrayName(element) == null)
			fail("E1016", "This array element type has no compiler-owned runtime ABI", span);
		if (name == "push" || name == "add") {
			if (arguments.length != 1)
				fail("E1008", 'Array.$name expects one argument', span);
			var value = coerce(typeExpression(arguments[0], scope, element), element, "array element", "E1002");
			return new TypedExpression(TArrayPush(receiver, value), TInt, span);
		}
		if (name == "iterator") {
			if (arguments.length != 0)
				fail("E1008", "Array.iterator expects no arguments", span);
			return receiver;
		}
		if (name == "unshift") {
			if (arguments.length != 1)
				fail("E1008", "Array.unshift expects one argument", span);
			var value = coerce(typeExpression(arguments[0], scope, element), element, "array element", "E1002");
			return new TypedExpression(TArrayUnshift(receiver, value), TInt, span);
		}
		if (name == "pop") {
			if (arguments.length != 0)
				fail("E1008", "Array.pop expects no arguments", span);
			return new TypedExpression(TArrayPop(receiver), element, span);
		}
		if (name == "shift") {
			if (arguments.length != 0)
				fail("E1008", "Array.shift expects no arguments", span);
			return new TypedExpression(TCollectionCall(receiver, "shift", []), element, span);
		}
		if (name == "resize") {
			if (arguments.length != 1)
				fail("E1008", "Array.resize expects one argument", span);
			var length = coerce(typeExpression(arguments[0], scope), TInt, "array length", "E1002");
			return new TypedExpression(TCollectionCall(receiver, "resize", [length]), TVoid, span);
		}
		if (name == "remove") {
			if (arguments.length != 1)
				fail("E1008", "Array.remove expects one argument", span);
			var value = coerce(typeExpression(arguments[0], scope, element), element, "array element", "E1002");
			return new TypedExpression(TCollectionCall(receiver, "remove", [value]), TBool, span);
		}
		if (name == "insert") {
			if (arguments.length != 2)
				fail("E1008", "Array.insert expects a position and value", span);
			var position = coerce(typeExpression(arguments[0], scope), TInt, "insert position", "E1002"),
				value = coerce(typeExpression(arguments[1], scope, element), element, "array element", "E1002");
			return new TypedExpression(TCollectionCall(receiver, "insert", [position, value]), TVoid, span);
		}
		if (name == "reverse") {
			if (arguments.length != 0)
				fail("E1008", "Array.reverse expects no arguments", span);
			return new TypedExpression(TCollectionCall(receiver, "reverse", []), TVoid, span);
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
		if (name == "splice") {
			if (arguments.length != 2)
				fail("E1008", "Array.splice expects a position and length", span);
			var position = coerce(typeExpression(arguments[0], scope), TInt, "splice position", "E1002"),
				length = coerce(typeExpression(arguments[1], scope), TInt, "splice length", "E1002");
			return new TypedExpression(TCollectionCall(receiver, "splice", [position, length]), TArray(element), span);
		}
		if (name == "sort") {
			if (arguments.length != 1)
				fail("E1008", "Array.sort expects one comparator", span);
			var comparatorType = CompilerType.TFunction([element, element], TInt),
				comparator = coerce(typeExpression(arguments[0], scope, comparatorType), comparatorType, "array comparator", "E1002");
			return new TypedExpression(TArraySort(receiver, comparator), TVoid, span);
		}
		if (name == "join") {
			if (!sameType(element, TString))
				fail("E1016", "Array.join currently requires String elements", span);
			if (arguments.length != 1)
				fail("E1008", "Array.join expects one separator", span);
			var separator = coerce(typeExpression(arguments[0], scope, TString), TString, "join separator", "E1002");
			return new TypedExpression(TCollectionCall(receiver, "join", [separator]), TString, span);
		}
		if (name == "indexOf") {
			switch element {
				case TInt, TFloat, TBool, TString:
				default:
					if (RuntimeType.arrayName(element) != "ref")
						fail("E1016", "Array.indexOf currently supports primitive, String, and reference arrays only", span);
			}
			if (arguments.length != 1)
				fail("E1008", "Array.indexOf expects one argument", span);
			var value = coerce(typeExpression(arguments[0], scope), element, "array element", "E1002");
			return new TypedExpression(TCollectionCall(receiver, "index_of", [value]), TInt, span);
		}
		throw new CompileError(new Diagnostic("E1007", 'Unknown array method "$name"', span));
	}

	function hasInstanceField(type:CompilerType, name:String):Bool
		return switch type {
			case TInstance(Class, className, []):
				var found = false;
				if (classDecls.exists(className)) {
					var classDecl = requiredMapValue(classDecls, className);
					for (field in classDecl.fields)
						if (field.name == name && !field.isStatic)
							found = true;
					var base = classDecl.base;
					if (!found && base != null)
						found = hasInstanceField(TInstance(NominalKind.Class, inheritanceName(base), []), name);
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
			var key = coerce(typeExpression(arguments[0], scope, mapType.key), mapType.key, "map key", "E1002"),
				value = coerce(typeExpression(arguments[1], scope, mapType.value), mapType.value, "map value", "E1002");
			var entryPath = FlowAnalysis.mapEntryPath(receiver, key);
			if (entryPath != null)
				scope.refineExpression(entryPath, mapType.value);
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
			var entriesPath = FlowAnalysis.mapEntriesPath(receiver);
			if (entriesPath != null)
				scope.invalidateExpressionNamespace(entriesPath);
			return new TypedExpression(TCollectionCall(receiver, "clear", []), TVoid, span);
		}
		if (name == "size") {
			if (arguments.length != 0)
				fail("E1008", "Map.size expects no arguments", span);
			return new TypedExpression(TCollectionCall(receiver, "size", []), TInt, span);
		}
		if (arguments.length != 1)
			fail("E1008", 'Map.$name expects one argument', span);
		var key = coerce(typeExpression(arguments[0], scope, mapType.key), mapType.key, "map key", "E1002");
		return switch name {
			case "exists": new TypedExpression(TCollectionCall(receiver, "exists", [key]), TBool, span);
			case "remove":
				var entryPath = FlowAnalysis.mapEntryPath(receiver, key);
				if (entryPath != null)
					scope.invalidateExpressionValue(entryPath);
				new TypedExpression(TCollectionCall(receiver, "remove", [key]), TBool, span);
			case "get":
				var entryPath = FlowAnalysis.mapEntryPath(receiver, key),
					refined = entryPath == null ? null : scope.resolveExpression(entryPath);
				new TypedExpression(TMapGet(receiver, key), refined == null ? nullableMapValue(mapType.value) : refined, span);
			default: throw new CompileError(new Diagnostic("E1007", 'Unknown map method "$name"', span));
		};
	}

	static function nullableMapValue(type:CompilerType):CompilerType
		return switch type {
			case TNullable(_): type;
			default: TNullable(type);
		};

	function functionType(fn:AstFunction):CompilerType
		return TFunction([for (argument in fn.arguments) argumentType(argument)], lowerType(fn.result));

	function coerceArguments(arguments:Array<TypedExpression>, expected:Array<CompilerType>, name:String):Array<TypedExpression> {
		var output:Array<TypedExpression> = [];
		for (i in 0...arguments.length)
			output.push(coerce(arguments[i], expected[i], 'argument ${i + 1} to "$name"'));
		return output;
	}

	function typeCallArguments(arguments:Array<AstExpression>, expected:Array<CompilerType>, scope:Scope, name:String):Array<TypedExpression> {
		var typed = [for (i in 0...arguments.length) typeExpression(arguments[i], scope, expected[i])];
		return coerceArguments(typed, expected, name);
	}

	function typeDeclaredCallArguments(arguments:Array<AstExpression>, parameters:Array<compiler.syntax.Ast.AstArgument>, scope:Scope, name:String,
			span:SourceSpan, ?substitutions:Map<String, CompilerType>):Array<TypedExpression> {
		var required = parameters.length;
		while (required > 0 && parameters[required - 1].optional)
			required--;
		if (arguments.length < required || arguments.length > parameters.length) {
			var expected = required == parameters.length ? '$required' : '$required to ${parameters.length}';
			fail("E1008", 'Function "$name" expects $expected arguments, got ${arguments.length}', span);
		}
		var typed = [
			for (i in 0...arguments.length)
				typeExpression(arguments[i], scope, argumentType(parameters[i], substitutions))
		];
		for (i in arguments.length...parameters.length) {
			var parameter = parameters[i],
				expected = argumentType(parameter, substitutions),
				defaultValue = parameter.defaultValue;
			if (isPosInfosParameter(parameter))
				typed.push(coerce(typeExpression(posInfosExpression(span), scope, expected), expected, 'position argument ${i + 1} to "$name"'));
			else if (defaultValue == null)
				typed.push(coerce(new TypedExpression(TNullLiteral, TNull, span), expected, 'default argument ${i + 1} to "$name"'));
			else
				typed.push(coerce(typeDefaultExpression(defaultValue, expected, name), expected, 'default argument ${i + 1} to "$name"'));
		}
		return coerceArguments(typed, [for (parameter in parameters) argumentType(parameter, substitutions)], name);
	}

	function typeInferredClassConstruction(typeName:String, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope,
			expectedType:Null<CompilerType>):TypedExpression {
		var declaration = requiredMapValue(classDecls, typeName),
			parameters = declaration.typeParameters,
			substitutions:Map<String, CompilerType> = [];
		var constructorExpectation = switch expectedType {
			case TNullable(element): element;
			default: expectedType;
		};
		var contextualArguments:Null<Array<CompilerType>> = null;
		switch constructorExpectation {
			case TInstance(NominalKind.Class, expectedName, values):
				if (expectedName == typeName)
					contextualArguments = values;
			default:
		}
		if (contextualArguments != null)
			for (index in 0...parameters.length)
				if (index < contextualArguments.length)
					substitutions.set(parameters[index], contextualArguments[index]);

		var constructorName = typeName + ".new",
			hasConstructor = signatures.exists(constructorName),
			implicitConstructor = !hasConstructor && [
				for (field in declaration.fields)
					if (!field.isStatic && field.initializer != null) field
			].length > 0;
		if (!hasConstructor) {
			if (arguments.length != 0)
				fail("E1008", 'Constructor "$typeName" expects 0 arguments, got ${arguments.length}', span);
		} else {
			var constructor = requiredMapValue(signatures, constructorName),
				required = constructor.arguments.length;
			while (required > 0 && constructor.arguments[required - 1].optional)
				required--;
			if (arguments.length < required || arguments.length > constructor.arguments.length) {
				var expected = required == constructor.arguments.length ? '$required' : '$required to ${constructor.arguments.length}';
				fail("E1008", 'Function "$constructorName" expects $expected arguments, got ${arguments.length}', span);
			}
		}

		var typed:Array<TypedExpression> = [],
			constructor = hasConstructor ? requiredMapValue(signatures, constructorName) : null;
		for (index in 0...arguments.length) {
			var expectedArgument:Null<CompilerType> = null;
			if (allTypeParametersBound(parameters, substitutions) && constructor != null)
				expectedArgument = declarations.resolve(constructor.arguments[index].type, constructor.arguments[index].span, substitutions);
			var argument = typeExpression(arguments[index], scope, expectedArgument);
			if (constructor != null)
				inferTypeParameters(constructor.arguments[index].type, argument.type, parameters, substitutions, argument.span);
			typed.push(argument);
		}
		for (parameter in parameters)
			if (!substitutions.exists(parameter))
				fail("E1003", 'Cannot infer generic type parameter "$parameter" for constructor "$typeName"', span);
		validateTypeParameterConstraints(typeName, declaration.typeConstraints, substitutions, span);

		if (constructor != null) {
			var semanticExpected = [
				for (parameter in constructor.arguments)
					argumentType(parameter, substitutions)
			];
			for (index in arguments.length...constructor.arguments.length) {
				var parameter = constructor.arguments[index],
					defaultValue = parameter.defaultValue;
				if (isPosInfosParameter(parameter))
					typed.push(typeExpression(posInfosExpression(span), scope, semanticExpected[index]));
				else if (defaultValue == null)
					typed.push(new TypedExpression(TNullLiteral, TNull, span));
				else
					typed.push(typeDefaultExpression(defaultValue, semanticExpected[index], constructorName));
			}
			typed = coerceArguments(typed, semanticExpected, constructorName);
		}
		var typeArguments = [for (parameter in parameters) requiredMapValue(substitutions, parameter)],
			valueType = TInstance(NominalKind.Class, typeName, typeArguments),
			representationSubstitutions:Map<String, CompilerType> = [];
		for (parameter in parameters)
			representationSubstitutions.set(parameter, TDynamic);
		var representationExpected:Array<CompilerType> = [];
		if (constructor != null)
			for (parameter in constructor.arguments)
				representationExpected.push(argumentType(parameter, representationSubstitutions));
		var representationArguments = [
			for (index in 0...typed.length)
				abiBoundaryCast(typed[index], representationExpected[index])
		];
		return new TypedExpression(TNew(typeName, representationArguments, hasConstructor || implicitConstructor), valueType, span);
	}

	static function allTypeParametersBound(parameters:Array<String>, substitutions:Map<String, CompilerType>):Bool {
		for (parameter in parameters)
			if (!substitutions.exists(parameter))
				return false;
		return true;
	}

	function validateTypeParameterConstraints(name:String, constraints:Null<Array<compiler.syntax.Ast.AstTypeConstraint>>,
			substitutions:Map<String, CompilerType>, span:SourceSpan):Void {
		if (constraints == null)
			return;
		for (constraint in constraints) {
			var actual = requiredMapValue(substitutions, constraint.parameter),
				expected = declarations.resolve(constraint.type, constraint.span, substitutions);
			if (!isAssignable(actual, expected))
				fail("E1003", 'Type argument for "${constraint.parameter}" on "$name" does not satisfy constraint "${SemanticSignature.type(expected)}"', span);
		}
	}

	function argumentType(argument:compiler.syntax.Ast.AstArgument, ?substitutions:Map<String, CompilerType>):CompilerType {
		var type = if (argument.type == InferredType && argument.defaultValue != null) {
			var inferred = knownExpressionType(argument.defaultValue);
			inferred == null ? TDynamic : inferred;
		} else substitutions == null ? lowerType(argument.type) : declarations.resolve(argument.type, argument.span, substitutions);
		return argument.optional && argument.defaultValue == null ? CompilerType.TNullable(type) : type;
	}

	static function isPosInfosParameter(argument:compiler.syntax.Ast.AstArgument):Bool
		return argument.optional && switch argument.type {
			case NamedType("haxe.PosInfos"): true;
			default: false;
		};

	function typeDefaultExpression(expression:AstExpression, expected:CompilerType, declarationName:String):TypedExpression {
		var body = enterBody("$default:" + declarationName, null, parentPath(declarationName));
		try {
			var typed = typeExpression(expression, new Scope(), expected);
			leaveBody(body);
			return typed;
		} catch (error:Dynamic) {
			leaveBody(body);
			throw error;
		}
	}

	function posInfosExpression(span:SourceSpan):AstExpression {
		var owner = parentPath(context.name),
			separator = context.name.lastIndexOf("."),
			method = separator < 0 ? context.name : context.name.substring(separator + 1, context.name.length);
		return ObjectLiteral([
			{name: "fileName", value: StringLiteral(span.file.path, span), span: span},
			{name: "lineNumber", value: IntegerLiteral(span.file.lineAt(span.start), span), span: span},
			{name: "className", value: StringLiteral(owner == null ? "" : owner, span), span: span},
			{name: "methodName", value: StringLiteral(method, span), span: span}
		], span);
	}

	function nominalSubstitutions(type:CompilerType):Map<String, CompilerType> {
		return declarations.inheritance.substitutions(type);
	}

	function projectNominal(type:CompilerType, target:String):CompilerType {
		var projected = declarations.inheritance.project(type, target);
		return projected == null ? type : projected;
	}

	static function nominalName(type:CompilerType):String
		return switch type {
			case TInstance(_, name, _): name;
			default: "";
		};

	static function inheritanceName(type:AstType):String
		return switch type {
			case NamedType(name), AppliedType(name, _): name;
			default: throw "Inheritance requires a nominal type";
		};

	function coerce(value:TypedExpression, expected:CompilerType, context:String, code:String = "E1009"):TypedExpression {
		if (value.type == TNever)
			return new TypedExpression(value.expression, expected, value.span);
		return switch relations.conversion(value.type, expected) {
			case Identity: value;
			case IntToFloat:
				new TypedExpression(TIntToFloat(value), TFloat, value.span);
			case ReferenceCast:
				new TypedExpression(TCast(value), expected, value.span);
			case AbstractCast:
				new TypedExpression(TAbiCast(value), expected, value.span);
			case ToDynamic:
				new TypedExpression(TToDynamic(value), expected, value.span);
			case ToInterface(name):
				new TypedExpression(TToInterface(value, name), expected, value.span);
			case WrapNullable:
				new TypedExpression(TNullableWrap(value), expected, value.span);
			case UnwrapNullable:
				new TypedExpression(TCast(value), expected, value.span);
			case Incompatible:
				fail(code, 'Type mismatch for $context', value.span);
				value;
		};
	}

	function isAssignable(actual:CompilerType, expected:CompilerType):Bool {
		return relations.isAssignable(actual, expected);
	}

	function findMethod(className:String, name:String):Null<SemanticMethodInfo> {
		var results:Array<SemanticMethodInfo> = [];
		findMethods(className, name, results);
		return results.length == 0 ? null : results[0];
	}

	function findMethods(className:String, name:String, results:Array<SemanticMethodInfo>):Void {
		if (results.length > 0)
			return;
		var key = className + "." + name;
		if (methodInfo.exists(key)) {
			results.push(requiredMapValue(methodInfo, key));
			return;
		}
		if (classDecls.exists(className)) {
			var base = requiredMapValue(classDecls, className).base;
			if (base != null)
				findMethods(inheritanceName(base), name, results);
			return;
		}
		if (interfaceDecls.exists(className))
			for (base in requiredMapValue(interfaceDecls, className).bases)
				findMethods(inheritanceName(base), name, results);
	}

	function enumCaseInfo(name:String):Null<{
		enumName:String,
		index:Int,
		params:Array<compiler.syntax.Ast.AstEnumParameter>,
		typeParameters:Array<String>
	}> {
		var parent = parentPath(name);
		if (parent == null)
			return null;
		var enumName = parent, caseName = lastPathSegment(name);
		if (!enumDecls.exists(enumName))
			return null;
		var declaration = requiredMapValue(enumDecls, enumName);
		for (index in 0...declaration.cases.length)
			if (declaration.cases[index].name == caseName)
				return {
					enumName: enumName,
					index: index,
					params: declaration.cases[index].params,
					typeParameters: declaration.typeParameters
				};
		return null;
	}

	function enumParameterType(typeParameters:Array<String>, parameter:compiler.syntax.Ast.AstEnumParameter, instance:Null<CompilerType>):CompilerType {
		var substitutions:Map<String, CompilerType> = [];
		for (index in 0...typeParameters.length) {
			var argument:CompilerType = TDynamic;
			var resolvedInstance = instance;
			if (resolvedInstance != null)
				switch resolvedInstance {
					case TInstance(Enum, _, arguments) if (index < arguments.length):
						argument = arguments[index];
					default:
				}
			substitutions.set(typeParameters[index], argument);
		}
		var resolved = declarations.resolve(parameter.type, parameter.span, substitutions);
		return parameter.optional ? TNullable(resolved) : resolved;
	}

	function enumStorageParameterType(typeParameters:Array<String>, parameter:compiler.syntax.Ast.AstEnumParameter):CompilerType {
		// A HashLink enum has one physical constructor layout for every source
		// specialization. Erase all payloads of a generic enum so two uses cannot
		// publish incompatible field representations for that shared layout.
		if (typeParameters.length > 0)
			return TDynamic;
		var substitutions:Map<String, CompilerType> = [];
		for (name in typeParameters)
			substitutions.set(name, TDynamic);
		var type = declarations.resolve(parameter.type, parameter.span, substitutions);
		return parameter.optional ? TNullable(type) : type;
	}

	function erasedEnumParameter(declaration:AstEnum, parameter:compiler.syntax.Ast.AstEnumParameter):CompilerType
		return enumStorageParameterType(declaration.typeParameters, parameter);

	function abiBoundaryCast(value:TypedExpression, target:CompilerType):TypedExpression
		return sameType(value.type, target) ? value : new TypedExpression(TAbiCast(value), target, value.span);

	static function requiredEnumParameters(parameters:Array<compiler.syntax.Ast.AstEnumParameter>):Int {
		var minimum = 0;
		for (index in 0...parameters.length)
			if (!parameters[index].optional)
				minimum = index + 1;
		return minimum;
	}

	function fieldType(type:CompilerType, name:String, span:SourceSpan):CompilerType {
		var platformField = PlatformAbi.field(type, name);
		if (platformField != null)
			return platformField.type;
		switch type {
			case TAnonymous(_, fields):
				for (field in fields)
					if (field.name == name)
						return field.type;
				throw new CompileError(new Diagnostic("E1005", 'Unknown anonymous field "$name"', span));
			case TInstance(Class, className, arguments):
				if (classDecls.exists(className)) {
					var classDecl = requiredMapValue(classDecls, className);
					for (field in classDecl.fields)
						if (field.name == name && !field.isStatic)
							return declarations.resolve(declarations.resolvedFieldType(className, field), field.span, nominalSubstitutions(type));
					var base = classDecl.base;
					if (base != null)
						return fieldType(declarations.resolve(base, classDecl.span, nominalSubstitutions(type)), name, span);
				}
				throw new CompileError(new Diagnostic("E1005", 'Unknown field "$className.$name"', span));
			default:
				throw new CompileError(new Diagnostic("E1005", 'Field "$name" requires an object', span));
		}
	}

	function resolveReceiver(name:String, span:SourceSpan, scope:Scope):Null<TypedExpression> {
		if (scope.resolve(name) != null)
			return typeExpression(Variable(name, span), scope);
		var thisType = scope.resolve("this");
		if (thisType != null && findFieldType(thisType, name) != null)
			return typeExpression(Variable(name, span), scope);
		var owner = context.lexicalOwner,
			staticField:Null<{owner:String, type:CompilerType}> = null;
		if (owner != null)
			staticField = findStaticFieldNullable(owner, name);
		if (staticField != null)
			return new TypedExpression(TStaticField(staticField.owner, name), staticField.type, span);
		return null;
	}

	function findFieldType(type:CompilerType, name:String):Null<CompilerType>
		return switch type {
			case TAnonymous(_, fields):
				var found:Null<CompilerType> = null;
				for (field in fields)
					if (field.name == name)
						found = field.type;
				found;
			case TInstance(Class, className, arguments):
				var found:Null<CompilerType> = null;
				if (classDecls.exists(className)) {
					var classDecl = requiredMapValue(classDecls, className);
					for (field in classDecl.fields)
						if (field.name == name && !field.isStatic)
							found = declarations.resolve(declarations.resolvedFieldType(className, field), field.span, nominalSubstitutions(type));
					var base = classDecl.base;
					if (found == null && base != null)
						found = findFieldType(declarations.resolve(base, classDecl.span, nominalSubstitutions(type)), name);
				}
				found;
			default: null;
		};

	function arithmetic(a:AstExpression, b:AstExpression, scope:Scope, add:Bool, span:SourceSpan):TypedExpression {
		var left = typeExpression(a, scope), right = typeExpression(b, scope);
		if (left.type == TNever && isNumeric(right.type))
			left = coerce(left, right.type, "arithmetic operand");
		if (right.type == TNever && isNumeric(left.type))
			right = coerce(right, left.type, "arithmetic operand");
		if (add && (isStringConvertible(left.type) || isStringConvertible(right.type))) {
			left = stringify(left);
			right = stringify(right);
			return new TypedExpression(TAdd(left, right), TString, span);
		}
		if (!isNumeric(left.type) || !isNumeric(right.type))
			fail("E1010", "Arithmetic requires matching Int or Float operands", span);
		var promoted = promoteNumericOperands(left, right);
		return new TypedExpression(add ? TAdd(promoted.left, promoted.right) : TSub(promoted.left, promoted.right), promoted.type, span);
	}

	function isStringConvertible(type:CompilerType):Bool
		return switch type {
			case TString: true;
			case TAbstract(_, _, _): isAssignable(type, TString);
			default: false;
		};

	function stringify(value:TypedExpression):TypedExpression {
		if (isStringConvertible(value.type))
			return coerce(value, TString, "string concatenation", "E1010");
		var dynamicValue = coerce(value, TDynamic, "string concatenation", "E1010");
		return new TypedExpression(TCall("__std_string", [dynamicValue]), TString, value.span);
	}

	function logical(a:AstExpression, b:AstExpression, scope:Scope, and:Bool, span:SourceSpan):TypedExpression {
		var left = typeExpression(a, scope),
			rightScope = FlowAnalysis.narrowedScope(scope, left, and),
			right = typeExpression(b, rightScope);
		if (!sameType(left.type, TBool) || !sameType(right.type, TBool))
			fail("E1011", "Logical operators require Bool operands", span);
		return new TypedExpression(and ? TAnd(left, right) : TOr(left, right), TBool, span);
	}

	function numeric(a:AstExpression, b:AstExpression, scope:Scope, operation:Int, span:SourceSpan):TypedExpression {
		var left = typeExpression(a, scope), right = typeExpression(b, scope);
		if (!isNumeric(left.type) || !isNumeric(right.type))
			fail("E1010", "Arithmetic requires matching Int or Float operands", span);
		var promoted = promoteNumericOperands(left, right, operation != 2);
		return new TypedExpression(operation == 2 ? TMul(promoted.left, promoted.right) : TDiv(promoted.left, promoted.right), promoted.type, span);
	}

	function isNumeric(type:CompilerType):Bool
		return sameType(type, TInt) || sameType(type, TFloat);

	function promoteNumericOperands(left:TypedExpression, right:TypedExpression, forceFloat:Bool = false):{
		left:TypedExpression,
		right:TypedExpression,
		type:CompilerType
	} {
		var type = forceFloat || sameType(left.type, TFloat) || sameType(right.type, TFloat) ? TFloat : TInt;
		return {left: coerce(left, type, "numeric operand", "E1010"), right: coerce(right, type, "numeric operand", "E1010"), type: type};
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
		var expression:TypedExpressionKind = switch operation {
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
		var left = typeExpression(a, scope),
			right = typeExpression(b, scope, left.type);
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
		if (operation == 2 && isAssignable(left.type, right.type)) {
			left = coerce(left, right.type, "equality comparison", "E1011");
			return new TypedExpression(TEqual(left, right), TBool, span);
		}
		if (operation == 2 && isAssignable(right.type, left.type)) {
			right = coerce(right, left.type, "equality comparison", "E1011");
			return new TypedExpression(TEqual(left, right), TBool, span);
		}
		if (operation == 2
			&& ((sameType(left.type, TNull) && TypeRelations.isReference(right.type))
				|| (sameType(right.type, TNull) && TypeRelations.isReference(left.type)))) {
			if (sameType(left.type, TNull))
				left = new TypedExpression(TNullableWrap(left), right.type, left.span);
			else
				right = new TypedExpression(TNullableWrap(right), left.type, right.span);
			return new TypedExpression(TEqual(left, right), TBool, span);
		}
		if (operation == 2 && (sameType(left.type, TNull) || sameType(right.type, TNull))) {
			var nullableComparison = switch left.type {
				case TNull:
					switch right.type {
						case TNullable(_): true;
						default: false;
					}
				case TNullable(_):
					switch right.type {
						case TNull, TNullable(_): true;
						default: false;
					}
				default: false;
			};
			if (nullableComparison)
				return new TypedExpression(TEqual(left, right), TBool, span);
		}
		if (operation == 2 && sameType(left.type, right.type))
			switch left.type {
				case TDynamic, TNativeAbstract(_), TAbstract(_, _, _), TInstance(Class, _, []), TInstance(Interface, _, []), TInstance(Enum, _, _),
					TNullable(_), TArray(_), TMap(_, _), TFunction(_, _), TAnonymous(_, _):
					return new TypedExpression(TEqual(left, right), TBool, span);
				default:
			}
		if (!isNumeric(left.type) || !isNumeric(right.type))
			fail("E1011", "Comparison requires matching Int or Float operands", span);
		var promoted = promoteNumericOperands(left, right);
		left = promoted.left;
		right = promoted.right;
		return new TypedExpression(switch operation {
			case 0: TLess(left, right);
			case 1: TLessEqual(left, right);
			default: TEqual(left, right);
		}, TBool, span);
	}

	function exhaustiveEnum(type:CompilerType, cases:Array<TypedSwitchCase>):Bool {
		var enumName = switch type {
			case TInstance(Enum, name, _): name;
			default: return false;
		};
		if (!enumDecls.exists(enumName))
			return false;
		var enumDecl = requiredMapValue(enumDecls, enumName);
		var seen:Map<Int, Bool> = [];
		for (switchCase in cases)
			if (switchCase.subjectBinding != null)
				return true;
			else if (switchCase.constructorIndex >= 0)
				seen.set(switchCase.constructorIndex, true);
		for (index in 0...enumDecl.cases.length)
			if (!seen.exists(index))
				return false;
		return true;
	}

	function lowerType(type:AstType):CompilerType
		return declarations.resolve(type, null, context.typeSubstitutions);

	static function copyMap<T>(source:Map<String, T>):Map<String, T> {
		var result:Map<String, T> = [];
		for (name => value in source)
			result.set(name, value);
		return result;
	}

	static function requiredMapValue<T>(source:Map<String, T>, name:String):T {
		if (!source.exists(name))
			throw 'Missing map entry "$name"';
		return source.get(name);
	}

	static function isGeneric(fn:AstFunction):Bool
		return functionTypeParameters(fn).length > 0;

	static function functionTypeParameters(fn:AstFunction):Array<String> {
		var parameters = fn.typeParameters;
		if (parameters == null)
			return [];
		return parameters;
	}

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
			case TInstance(Enum, _, _): true;
			case TNullable(inner): isEnum(inner);
			default: false;
		};

	static function isNullableEnum(type:CompilerType):Bool
		return switch type {
			case TNullable(inner): isEnum(inner);
			default: false;
		};

	static function isNullable(type:CompilerType):Bool
		return switch type {
			case TNullable(_): true;
			default: false;
		};

	static function isReference(type:CompilerType):Bool
		return switch type {
			case TString, TDynamic, TInstance(Class, _, []), TInstance(Interface, _, []), TAnonymous(_, _), TArray(_), TFunction(_, _), TMap(_, _): true;
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
		return SemanticSignature.anonymousTypeName(fields);

	function registerAnonymousTypes(type:CompilerType):Void
		switch type {
			case TAnonymous(name, fields):
				if (anonymousTypes.exists(name))
					return;
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
			case ErrorStatement(span): span;
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
