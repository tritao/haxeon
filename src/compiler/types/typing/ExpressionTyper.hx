package compiler.types.typing;

import compiler.runtime.PlatformAbi;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceSpan;
import compiler.ffi.HxiAbi;
import compiler.ffi.NativeLayout;
import compiler.semantic.SemanticSignature;
import compiler.types.NativeTypeDescriptor;
import compiler.types.NativeTypeDescriptor.NativeTypeDescriptorField;
import compiler.types.NativeTypeDescriptor.NativeTypeDescriptorData;
import compiler.types.NativeTypeDescriptor.NativeTypeDescriptorDefault;
import compiler.types.NativeTypeDescriptor.NativeTypeAnnotationData;
import compiler.types.NativeTypeDescriptor.NativeTypeAnnotationArgument;
import compiler.types.NativeTypeDescriptor.NativeTypeAnnotationValue;
import compiler.types.NativeTypeDescriptor.NativeTypeAnnotationValue.*;
import compiler.syntax.Ast.AstMetadata;
import compiler.syntax.Ast.AstProgram;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstField;
import compiler.syntax.Ast.AstEnumAbstract;
import compiler.syntax.Ast.AstMapEntry;
import compiler.syntax.Ast.AstObjectField;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstSwitchExpressionCase;
import compiler.syntax.Ast.AstType;
import compiler.types.analysis.AstScan;
import compiler.types.analysis.FlowAnalysis;
import compiler.types.analysis.Scope;
import compiler.types.Type.AnonymousField;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.TypedAst.TypedExpressionKind;
import compiler.types.TypedAst.TypedMapEntry;
import compiler.types.TypedAst.TypedObjectField;
import compiler.types.TypedAst.TypedSwitchBinding;
import compiler.types.TypedAst.TypedSwitchExpressionCase;
import compiler.types.TypedAst.TypedSwitchPredicate;
import compiler.types.TypedAst.TypedSwitchCoverageCase;
import compiler.types.TypedAst.TypedSwitchArrayPattern;
import compiler.types.Type.CompilerType;
import compiler.types.TypeRelations;
import compiler.types.IterationProtocol;
import compiler.types.StructProperties;

typedef ExpressionTypeCallback = (AstExpression, Scope, Null<CompilerType>, Bool) -> TypedExpression;
typedef ExpressionCoerceCallback = (TypedExpression, CompilerType, String, String) -> TypedExpression;
typedef ExpressionSwitchArrayPatternCallback = (AstExpression, CompilerType, Scope) -> Null<TypedSwitchArrayPattern>;
typedef ExpressionSwitchArrayPatternKeyCallback = TypedSwitchArrayPattern->Null<String>;
typedef ExpressionArrayElementTypeCallback = (CompilerType, SourceSpan) -> CompilerType;
typedef ContextualExpressionTypeCallback = (AstExpression, Scope) -> Null<CompilerType>;
typedef LowerExpressionTypeCallback = AstType->CompilerType;
typedef ExpressionVariableCallback = (String, SourceSpan, Scope, Null<CompilerType>) -> TypedExpression;
typedef ExpressionLambdaCallback = (Array<AstArgument>, Array<AstStatement>, String, SourceSpan, Scope, Null<CompilerType>, Bool) -> TypedExpression;
typedef ExpressionMemberCallback = (AstExpression, String, SourceSpan, Scope) -> TypedExpression;
typedef ExpressionBlockCallback = (Array<AstStatement>, AstExpression, SourceSpan, Scope, Null<CompilerType>) -> TypedExpression;
typedef ExpressionMethodCallCallback = (AstExpression, String, Array<AstExpression>, SourceSpan, Scope, Null<CompilerType>) -> TypedExpression;

typedef ExpressionDispatchRules = {
	variable:ExpressionVariableCallback,
	lambda:ExpressionLambdaCallback,
	member:ExpressionMemberCallback,
	block:ExpressionBlockCallback,
	methodCall:ExpressionMethodCallCallback,
	contextualType:ContextualExpressionTypeCallback
};

typedef ExpressionSwitchPattern = {
	value:TypedExpression,
	enumName:String,
	index:Int,
	bindings:Array<TypedSwitchBinding>,
	predicates:Array<TypedSwitchPredicate>
};

typedef ExpressionSwitchRules = {
	subjectBinding:(AstExpression, CompilerType, Scope) -> Null<String>,
	catchAll:AstExpression->Bool,
	enumPattern:(AstExpression, CompilerType, Scope) -> Null<ExpressionSwitchPattern>,
	arrayPattern:ExpressionSwitchArrayPatternCallback,
	arrayPatternKey:ExpressionSwitchArrayPatternKeyCallback,
	caseKey:(TypedExpression, Array<TypedSwitchPredicate>) -> Null<String>,
	enumCaseCovered:(CompilerType, Int, Array<TypedSwitchCoverageCase>) -> Bool,
	enumLiteral:TypedExpression->Null<{name:String, index:Int}>,
	isEnum:CompilerType->Bool,
	isNullableEnum:CompilerType->Bool,
	enumName:CompilerType->Null<String>
};

/** Dispatches source expressions and owns their expression-specific typing rules. */
class ExpressionTyper {
	final session:TypingSession;
	final conversionResolver:ConversionResolver;
	final callResolver:CallResolver;
	final typeExpressionCallback:ExpressionTypeCallback;
	final coerce:ExpressionCoerceCallback;
	final switchRules:ExpressionSwitchRules;
	final anonymousTypeRegistry:AnonymousTypeRegistry;
	final arrayElementType:ExpressionArrayElementTypeCallback;
	final lowerType:LowerExpressionTypeCallback;
	final dispatchRules:ExpressionDispatchRules;
	var typedAnnotationValues:Map<String, Array<NativeTypeAnnotationData>> = [];

	public function new(session:TypingSession, conversionResolver:ConversionResolver, callResolver:CallResolver, typeExpression:ExpressionTypeCallback,
			coerce:ExpressionCoerceCallback, switchRules:ExpressionSwitchRules, anonymousTypeRegistry:AnonymousTypeRegistry,
			arrayElementType:ExpressionArrayElementTypeCallback, lowerType:LowerExpressionTypeCallback, dispatchRules:ExpressionDispatchRules) {
		this.session = session;
		this.conversionResolver = conversionResolver;
		this.callResolver = callResolver;
		this.typeExpressionCallback = typeExpression;
		this.coerce = coerce;
		this.switchRules = switchRules;
		this.anonymousTypeRegistry = anonymousTypeRegistry;
		this.arrayElementType = arrayElementType;
		this.lowerType = lowerType;
		this.dispatchRules = dispatchRules;
	}

	/** Dispatches each source expression to its focused typing rule or semantic resolver. */
	public function typeExpression(expression:AstExpression, scope:Scope, ?expectedType:CompilerType, inferDynamicLambdaResult:Bool = false):TypedExpression
		return switch expression {
			case IntegerLiteral(_, _), FloatLiteral(_, _), StringLiteral(_, _), BoolLiteral(_, _), NullLiteral(_), Unreachable(_), EmptyExpression(_),
				ErrorExpression(_):
				typeLiteral(expression, expectedType);
			case Variable(name, span): dispatchRules.variable(name, span, scope, expectedType);
			case Lambda(arguments, body, identity, span): dispatchRules.lambda(arguments, body, identity, span, scope, expectedType, inferDynamicLambdaResult);
			case Member(object, name, span): dispatchRules.member(object, name, span, scope);
			case Add(left, right, span): arithmetic(left, right, scope, true, span, expectedType);
			case Sub(left, right, span): arithmetic(left, right, scope, false, span, expectedType);
			case Mul(left, right, span): numeric(left, right, scope, 2, span);
			case Div(left, right, span): numeric(left, right, scope, 3, span);
			case Mod(left, right, span): modulo(left, right, scope, span);
			case BitAnd(left, right, span): bitwise(left, right, scope, 0, span);
			case BitXor(left, right, span): bitwise(left, right, scope, 1, span);
			case BitOr(left, right, span): bitwise(left, right, scope, 2, span);
			case ShiftLeft(left, right, span): bitwise(left, right, scope, 3, span);
			case ShiftRight(left, right, span): bitwise(left, right, scope, 4, span);
			case UnsignedShiftRight(left, right, span): bitwise(left, right, scope, 5, span);
			case Negate(value, span): negate(value, span, scope, expectedType);
			case Less(left, right, span): comparison(left, right, scope, 0, span);
			case LessEqual(left, right, span): comparison(left, right, scope, 1, span);
			case Greater(left, right, span): comparison(left, right, scope, 0, span, ">", true);
			case GreaterEqual(left, right, span): comparison(left, right, scope, 1, span, ">=", true);
			case Equal(left, right, span): comparison(left, right, scope, 2, span);
			case NotEqual(left, right, span): notEqual(left, right, scope, span);
			case Not(value, span): logicalNot(value, span, scope);
			case And(left, right, span): logical(left, right, scope, true, span);
			case Or(left, right, span): logical(left, right, scope, false, span);
			case Conditional(predicate, whenTrue, whenFalse, span):
				typeConditional(predicate, whenTrue, whenFalse, span, scope, expectedType, dispatchRules.contextualType);
			case BlockExpression(statements, result, span): dispatchRules.block(statements, result, span, scope, expectedType);
			case ThrowExpression(value, span): throwExpression(value, span, scope);
			case Cast(value, target, span): typeCast(value, target, span, scope, expectedType, lowerType);
			case PostfixIncrement(target, delta, span): postfixIncrement(target, delta, span, scope);
			case SwitchExpression(subject, cases, defaultExpression, span): typeSwitchExpression(subject, cases, defaultExpression, span, scope, expectedType);
			case ObjectLiteral(fields, span): typeObjectLiteral(fields, span, scope, expectedType);
			case ArrayLiteral(values, span): typeArrayLiteral(values, span, scope, expectedType);
			case MapLiteral(entries, span): typeMapLiteral(entries, span, scope, expectedType);
			case ArrayComprehension(keyName, valueName, iterable, predicate, value, flattened, span):
				typeArrayComprehension(keyName, valueName, iterable, predicate, value, flattened, span, scope, expectedType);
			case MapComprehension(keyName, valueName, iterable, predicate, key, value, span):
				typeMapComprehension(keyName, valueName, iterable, predicate, key, value, span, scope, expectedType);
			case Range(start, rangeEnd, span): typeRange(start, rangeEnd, span, scope);
			case NativeLayoutQuery(kind, type, field, span): typeNativeLayoutQuery(kind, type, field, span, scope);
			case NewGeneric(typeName, typeArguments, arguments, span):
				callResolver.typeConstruction(typeName, typeArguments, arguments, span, scope, expectedType, true);
			case New(typeName, arguments, span): callResolver.typeConstruction(typeName, [], arguments, span, scope, expectedType, false);
			case NewArray(element, length, span): typeNewArray(element, length, span, scope, lowerType);
			case NewMap(key, value, span): typeNewMap(key, value, span, lowerType);
			case Index(array, offset, span): typeIndex(array, offset, span, scope);
			case Call(name, arguments, span):
				var rawPointerCall = callResolver.typeRawPointerNullCall(name, arguments, span, expectedType);
				if (rawPointerCall != null)
					return rawPointerCall;
				if (name == "super")
					return callResolver.typeSuperCall(arguments, span, scope);
				var runtimeDataCall = callResolver.typeRuntimeDataCall(name, arguments, span, scope);
				if (runtimeDataCall != null)
					return runtimeDataCall;
				var builtinCall = callResolver.typeBuiltinCall(name, arguments, span, scope, expectedType);
				if (builtinCall != null)
					return builtinCall;
				callResolver.typeNamedCall(name, arguments, span, scope, expectedType);
			case ClosureCall(callee, arguments, span): callResolver.typeClosureCall(callee, arguments, span, scope, null, true, expectedType);
			case MethodCall(object, name, arguments, span):
				var call = dispatchRules.methodCall(object, name, arguments, span, scope, expectedType);
				if (!isPureCallExpression(call))
					scope.invalidateAllExpressions();
				call;
		};

	function typeNativeLayoutQuery(kind:compiler.syntax.Ast.NativeLayoutQueryKind, type:AstType, field:Null<String>, span:SourceSpan,
			scope:Scope):TypedExpression {
		var resolved = session.declarations.resolve(type, span, session.currentContext.typeSubstitutions), size:Int;
		if (kind == TypeInfo)
			return typeNativeTypeInfo(resolved, span, scope);
		var recordName:Null<String> = switch resolved {
			case TInstance(NominalKind.NativeValue, name, _): name;
			case TInstance(NominalKind.Class, name, _) if (isFlatStruct(name)): name;
			case _: null;
		};
		if (recordName != null)
			return typeRecordLayoutQuery(recordName, kind, field, span);
		if (kind == OffsetOf)
			fail("E1022", "offsetof requires a flat struct or native value record type", span);
		var hxiType = try NativeLayout.fieldType(resolved) catch (_:Dynamic) {
			fail("E1022", 'Type "$resolved" has no fixed native ABI layout', span);
			cast null;
		}, layout = HxiAbi.forTarget(session.nativeAbiTarget).layout(hxiType);
		if (layout == null)
			fail("E1022", 'Type "$resolved" has no fixed native ABI layout for "${session.nativeAbiTarget}"', span);
		size = switch kind {
			case SizeOf: layout.size;
			case AlignOf: layout.align;
			case OffsetOf: 0;
			case TypeInfo: throw "typeInfo was dispatched before scalar layout query handling";
		};
		return new TypedExpression(TIntLiteral(size), TInt, span);
	}

	function isFlatStruct(name:String):Bool {
		var declaration = session.classDecls.get(name);
		return declaration != null
			&& (declaration.isStruct == true || hasCRepresentation(declaration))
			&& StructProperties.satisfies(session.declarations, TInstance(NominalKind.Class, name, []), StructProperties.FLAT_TYPE_NAME);
	}

	static function hasCRepresentation(declaration:compiler.syntax.Ast.AstClass):Bool {
		for (metadata in declaration.metadata)
			if (metadata.name == "repr" && metadata.arguments.length == 1)
				switch metadata.arguments[0] {
					case compiler.syntax.Ast.AstExpression.StringLiteral("C", _):
						return true;
					case _:
				}
		return false;
	}

	function typeRecordLayoutQuery(name:String, kind:compiler.syntax.Ast.NativeLayoutQueryKind, field:Null<String>, span:SourceSpan):TypedExpression {
		var layout = session.nativeLayoutsByName.get(name);
		if (layout == null)
			fail("E1022", 'Record "$name" has no layout for ABI target "${session.nativeAbiTarget}"', span);
		var size = switch kind {
			case SizeOf: layout.size;
			case AlignOf: layout.alignment;
			case OffsetOf:
				if (field == null)
					fail("E1022", "offsetof requires a field name", span);
				var found:Null<Int> = null;
				for (candidate in layout.fields)
					if (candidate.name == field)
						found = candidate.offset;
				if (found == null)
					fail("E1022", 'Record "$name" has no field "$field"', span);
				cast found;
			case TypeInfo: throw "typeInfo was dispatched before scalar layout query handling";
		};
		return new TypedExpression(TIntLiteral(size), TInt, span);
	}

	function typeNativeTypeInfo(resolved:CompilerType, span:SourceSpan, scope:Scope):TypedExpression {
		var name = descriptorRecordName(resolved);
		if (name == null)
			fail("E1022", 'typeInfo requires a struct or legacy C value record, got "${SemanticSignature.type(resolved)}"', span);
		var descriptor = buildNativeTypeDescriptor(resolved);
		if (descriptor == null)
			fail("E1022", 'Value "$name" has no source declaration for typeInfo', span);
		var annotationArgumentType:CompilerType = TAnonymous("$haxeon.TypeInfoAnnotationArgument.v3", [
			{
				name: "name",
				type: TString,
				optional: false,
				isFinal: true
			},
			{
				name: "type",
				type: TString,
				optional: false,
				isFinal: true
			},
			{
				name: "value",
				type: TDynamic,
				optional: false,
				isFinal: true
			}
		]),
			annotationType:CompilerType = TAnonymous("$haxeon.TypeInfoAnnotation.v3",
				[
					{
						name: "name",
						type: TString,
						optional: false,
						isFinal: true
					},
					{
						name: "arguments",
						type: TArray(annotationArgumentType),
						optional: false,
						isFinal: true
					}
				]),
			nodeFields:Array<AnonymousField> = [],
			nodeType:CompilerType = TAnonymous("$haxeon.TypeInfoNode.v4", nodeFields),
			defaultType:CompilerType = TAnonymous("$haxeon.TypeInfoDefault.v1", [
				{
					name: "type",
					type: TString,
					optional: false,
					isFinal: true
				},
				{
					name: "value",
					type: TDynamic,
					optional: false,
					isFinal: true
				}
			]);
		nodeFields.push({
			name: "name",
			type: TString,
			optional: false,
			isFinal: true
		});
		nodeFields.push({
			name: "type",
			type: TString,
			optional: false,
			isFinal: true
		});
		nodeFields.push({
			name: "flat",
			type: TBool,
			optional: false,
			isFinal: true
		});
		nodeFields.push({
			name: "portable",
			type: TBool,
			optional: false,
			isFinal: true
		});
		nodeFields.push({
			name: "size",
			type: TNullable(TInt),
			optional: false,
			isFinal: true
		});
		nodeFields.push({
			name: "alignment",
			type: TNullable(TInt),
			optional: false,
			isFinal: true
		});
		nodeFields.push({
			name: "offset",
			type: TNullable(TInt),
			optional: false,
			isFinal: true
		});
		nodeFields.push({
			name: "defaultValue",
			type: TNullable(defaultType),
			optional: false,
			isFinal: true
		});
		nodeFields.push({
			name: "annotations",
			type: TArray(TString),
			optional: false,
			isFinal: true
		});
		nodeFields.push({
			name: "annotationValues",
			type: TArray(annotationType),
			optional: false,
			isFinal: true
		});
		nodeFields.push({
			name: "fields",
			type: TArray(nodeType),
			optional: false,
			isFinal: true
		});
		nodeFields.push({
			name: "arguments",
			type: TArray(nodeType),
			optional: false,
			isFinal: true
		});
		nodeFields.push({
			name: "recursive",
			type: TBool,
			optional: false,
			isFinal: true
		});
		var descriptorSizeType:CompilerType = TNullable(TInt),
			descriptorAlignmentType:CompilerType = TNullable(TInt),
			descriptorFields:Array<AnonymousField> = [
				{
					name: "version",
					type: TInt,
					optional: false,
					isFinal: true
				},
				{
					name: "name",
					type: TString,
					optional: false,
					isFinal: true
				},
				{
					name: "type",
					type: TString,
					optional: false,
					isFinal: true
				},
				{
					name: "sourceKind",
					type: TString,
					optional: false,
					isFinal: true
				},
				{
					name: "interfaces",
					type: TArray(TString),
					optional: false,
					isFinal: true
				},
				{
					name: "flat",
					type: TBool,
					optional: false,
					isFinal: true
				},
				{
					name: "portable",
					type: TBool,
					optional: false,
					isFinal: true
				},
				{
					name: "size",
					type: descriptorSizeType,
					optional: false,
					isFinal: true
				},
				{
					name: "alignment",
					type: descriptorAlignmentType,
					optional: false,
					isFinal: true
				},
				{
					name: "annotations",
					type: TArray(TString),
					optional: false,
					isFinal: true
				},
				{
					name: "annotationValues",
					type: TArray(annotationType),
					optional: false,
					isFinal: true
				},
				{
					name: "fields",
					type: TArray(nodeType),
					optional: false,
					isFinal: true
				},
				{
					name: "arguments",
					type: TArray(nodeType),
					optional: false,
					isFinal: true
				},
				{
					name: "hash",
					type: TString,
					optional: false,
					isFinal: true
				}
			],
			descriptorType:CompilerType = TAnonymous("$haxeon.TypeInfo.v4", descriptorFields),
			descriptorExpression = ObjectLiteral([
				objectField("version", IntegerLiteral(descriptor.version, span), span),
				objectField("name", StringLiteral(descriptor.name, span), span),
				objectField("type", StringLiteral(descriptor.type, span), span),
				objectField("sourceKind", StringLiteral(descriptor.sourceKind, span), span),
				objectField("interfaces", stringArray(descriptor.interfaces, span), span),
				objectField("flat", BoolLiteral(descriptor.flat, span), span),
				objectField("portable", BoolLiteral(descriptor.portable, span), span),
				objectField("size", nullableInteger(descriptor.size, span), span),
				objectField("alignment", nullableInteger(descriptor.alignment, span), span),
				objectField("annotations", stringArray(descriptor.annotations, span), span),
				objectField("annotationValues", annotationValuesExpression(descriptor.annotationValues, span), span),
				objectField("fields", ArrayLiteral([for (field in descriptor.fields) descriptorFieldExpression(field, span)], span), span),
				objectField("arguments", ArrayLiteral([for (argument in descriptor.arguments) descriptorFieldExpression(argument, span)], span), span),
				objectField("hash", StringLiteral(descriptor.hash, span), span)
			], span);
		return typeExpressionCallback(descriptorExpression, scope, descriptorType, false);
	}

	/** Descriptors for every source struct and legacy C record in this typed program. */
	public function nativeTypeDescriptors():Array<NativeTypeDescriptorData> {
		var names = [
			for (name in session.classDecls.keys())
				if (isStructDeclaration(session.classDecls.get(name))) name
		];
		names.sort(Reflect.compare);
		var descriptors:Array<NativeTypeDescriptorData> = [];
		for (name in names) {
			var declaration = session.classDecls.get(name),
				kind = hasCRepresentation(declaration) ? NominalKind.NativeValue : NominalKind.Class,
				descriptor = buildNativeTypeDescriptor(TInstance(kind, name, []));
			if (descriptor != null)
				descriptors.push(descriptor);
		}
		return descriptors;
	}

	/** Type-checks declared annotations on struct declarations and stored fields and records their constant values. */
	public function prepareNativeTypeAnnotations(program:AstProgram):Void {
		typedAnnotationValues = [];
		var structSchemas:Map<String, AstClass> = [],
			abstractSchemas:Map<String, AstEnumAbstract> = [];
		for (declaration in program.classes)
			if (hasMetadata(declaration.metadata, "annotation")) {
				validateAnnotationMarker(declaration.metadata);
				if (declaration.isStruct != true)
					fail("E1024", '@:annotation requires a value struct declaration', declaration.span);
				if (declaration.methods.length != 0)
					fail("E1024", 'Annotation struct "${declaration.name}" cannot declare methods', declaration.span);
				for (field in declaration.fields)
					if (field.isStatic || field.type == null)
						fail("E1024", 'Annotation struct "${declaration.name}" requires explicitly typed instance fields', field.span);
				if (abstractSchemas.exists(declaration.name))
					fail("E1024", 'Duplicate annotation declaration "${declaration.name}"', declaration.span);
				structSchemas.set(declaration.name, declaration);
			}
		for (declaration in program.enumAbstracts)
			if (hasMetadata(declaration.metadata, "annotation")) {
				if (structSchemas.exists(declaration.name))
					fail("E1024", 'Duplicate annotation declaration "${declaration.name}"', declaration.span);
				validateAnnotationMarker(declaration.metadata);
				var underlying = session.declarations.resolve(declaration.underlying, declaration.span, []);
				if (!isAnnotationScalar(underlying))
					fail("E1024", 'Annotation enum abstract "${declaration.name}" must use a supported scalar representation', declaration.span);
				abstractSchemas.set(declaration.name, declaration);
			}

		var annotationNames:Map<String, Bool> = [];
		for (name in structSchemas.keys())
			annotationNames.set(name, true);
		for (name in abstractSchemas.keys())
			annotationNames.set(name, true);
		for (name in structSchemas.keys()) {
			var schema = structSchemas.get(name);
			for (field in schema.fields) {
				var expected = session.declarations.resolve(field.type, field.span, []);
				if (!isAnnotationScalar(expected))
					fail("E1024", 'Annotation field "${name}.${field.name}" must use a supported scalar type', field.span);
				if (field.initializer != null)
					typeAnnotationArgument(field.name, expected, field.initializer, {name: name, arguments: [], span: field.span});
			}
		}

		for (declaration in program.classes)
			if (isStructDeclaration(session.classDecls.get(declaration.name))) {
				typeAnnotationUses(declaration.metadata, declaration.name, annotationNames, structSchemas, abstractSchemas);
				for (field in declaration.fields)
					if (!field.isStatic)
						typeAnnotationUses(field.metadata, declaration.name + "." + field.name, annotationNames, structSchemas, abstractSchemas);
			}
	}

	function typeAnnotationUses(metadata:Array<AstMetadata>, owner:String, annotationNames:Map<String, Bool>, structSchemas:Map<String, AstClass>,
			abstractSchemas:Map<String, AstEnumAbstract>):Void {
		var seen:Map<String, Bool> = [];
		for (annotation in metadata) {
			if (annotation.name == "annotation" || isBuiltInMetadata(annotation.name))
				continue;
			if (!annotationNames.exists(annotation.name))
				fail("E1024", 'Unknown annotation "${annotation.name}" on "$owner"', annotation.span);
			if (seen.exists(annotation.name))
				fail("E1024", 'Annotation "${annotation.name}" is repeated on "$owner"', annotation.span);
			seen.set(annotation.name, true);
			var arguments:Array<NativeTypeAnnotationArgument> = [];
			if (structSchemas.exists(annotation.name)) {
				var schema = structSchemas.get(annotation.name),
					fields = [for (field in schema.fields) if (!field.isStatic) field],
					fieldsByName:Map<String, AstField> = [for (field in fields) field.name => field],
					argumentsByName:Map<String, AstExpression> = [],
					namedSeen = false,
					positionalCount = 0;
				for (argument in annotation.arguments) {
					var named = namedAnnotationArgument(argument);
					if (named != null) {
						namedSeen = true;
						if (!fieldsByName.exists(named.name))
							fail("E1024", 'Annotation "${annotation.name}" has unknown named argument "${named.name}"', named.span);
						if (argumentsByName.exists(named.name))
							fail("E1024", 'Duplicate named argument "${named.name}" for annotation "${annotation.name}"', named.span);
						argumentsByName.set(named.name, named.value);
					} else {
						if (namedSeen)
							fail("E1024", "Positional annotation arguments cannot follow named arguments", annotation.span);
						if (positionalCount >= fields.length)
							fail("E1024", 'Annotation "${annotation.name}" expects ${fields.length} arguments, got ${annotation.arguments.length}',
								annotation.span);
						argumentsByName.set(fields[positionalCount].name, argument);
						positionalCount++;
					}
				}
				for (index in 0...fields.length) {
					var field = fields[index],
						expected = session.declarations.resolve(field.type, field.span, []),
						expression = argumentsByName.get(field.name);
					if (expression == null)
						expression = field.initializer;
					if (expression == null) {
						if (!namedSeen && annotation.arguments.length < fields.length)
							fail("E1024", 'Annotation "${annotation.name}" expects ${fields.length} arguments, got ${annotation.arguments.length}',
								annotation.span);
						fail("E1024", 'Annotation "${annotation.name}" is missing required argument "${field.name}"', annotation.span);
					}
					arguments.push(typeAnnotationArgument(field.name, expected, expression, annotation));
				}
			} else {
				var schema = abstractSchemas.get(annotation.name);
				if (schema == null)
					fail("E1024", 'Unknown annotation "${annotation.name}" on "$owner"', annotation.span);
				var expected = session.declarations.resolve(schema.underlying, schema.span, []);
				if (annotation.arguments.length != 1)
					fail("E1024", 'Annotation "${annotation.name}" expects one argument, got ${annotation.arguments.length}', annotation.span);
				arguments.push(typeAnnotationArgument("value", expected, annotation.arguments[0], annotation));
			}
			typedAnnotationValues.set(metadataKey(annotation), [{name: annotation.name, arguments: arguments}]);
		}
	}

	static function namedAnnotationArgument(expression:AstExpression):Null<{
		name:String,
		value:AstExpression,
		span:SourceSpan
	}> {
		return switch expression {
			case BlockExpression(statements, result, span) if (statements.length == 1):
				switch statements[0] {
					case compiler.syntax.Ast.AstStatement.Assignment(assignedName, value, _):
						switch result {
							case Variable(resultName, _) if (assignedName == resultName): {name: assignedName, value: value, span: span};
							case _: null;
						}
					case _: null;
				}
			case _: null;
		};
	}

	function typeAnnotationArgument(name:String, expected:CompilerType, expression:AstExpression, annotation:AstMetadata):NativeTypeAnnotationArgument {
		var typed = coerce(typeExpressionCallback(expression, new Scope(), expected, false), expected, 'annotation argument "$name"', "E1024"),
			value = annotationConstant(typed, annotation);
		return {name: name, type: SemanticSignature.type(expected), value: value};
	}

	function annotationConstant(expression:TypedExpression, annotation:AstMetadata):NativeTypeAnnotationValue
		return switch expression.expression {
			case TIntLiteral(value): IntValue(value);
			case TFloatLiteral(value) if (Math.isFinite(value)): FloatValue(value);
			case TStringLiteral(value): StringValue(value);
			case TBoolLiteral(value): BoolValue(value);
			case TNullLiteral: NullValue;
			case TNullableWrap(value): annotationConstant(value, annotation);
			case TNegate(value):
				switch value.expression {
					case TIntLiteral(integer): IntValue(-integer);
					case TFloatLiteral(number) if (Math.isFinite(number)): FloatValue(-number);
					case _: invalidAnnotationConstant(annotation);
				}
			case TIntToFloat(value):
				switch value.expression {
					case TIntLiteral(integer): FloatValue(integer);
					case _: invalidAnnotationConstant(annotation);
				}
			case TFloatToInt(value):
				switch value.expression {
					case TFloatLiteral(number): IntValue(Std.int(number));
					case _: invalidAnnotationConstant(annotation);
				}
			case _: invalidAnnotationConstant(annotation);
		};

	static function invalidAnnotationConstant(annotation:AstMetadata):NativeTypeAnnotationValue
		return throw new CompileError(new Diagnostic("E1024", "Annotation values must be compile-time scalar constants", annotation.span));

	function typedMetadata(metadata:Array<AstMetadata>):Array<NativeTypeAnnotationData> {
		var result:Array<NativeTypeAnnotationData> = [];
		for (annotation in metadata) {
			if (annotation.name == "renamedFrom") {
				if (annotation.arguments.length != 1)
					fail("E1024", "@:renamedFrom requires exactly one string literal", annotation.span);
				var oldName = switch annotation.arguments[0] {
					case StringLiteral(value, _): value;
					case _: throw new CompileError(new Diagnostic("E1024", "@:renamedFrom requires exactly one string literal", annotation.span));
				};
				if (oldName.length == 0)
					fail("E1024", "@:renamedFrom cannot name an empty field", annotation.span);
				result.push({name: "renamedFrom", arguments: [{name: "value", type: "String", value: StringValue(oldName)}]});
				continue;
			}
			var values = typedAnnotationValues.get(metadataKey(annotation));
			if (values != null)
				for (value in values)
					result.push(value);
		}
		return result;
	}

	static function metadataKey(metadata:AstMetadata):String
		return metadata.span.file.path + ":" + metadata.span.start;

	static function hasMetadata(metadata:Array<AstMetadata>, name:String):Bool {
		for (annotation in metadata)
			if (annotation.name == name)
				return true;
		return false;
	}

	static function validateAnnotationMarker(metadata:Array<AstMetadata>):Void
		for (annotation in metadata)
			if (annotation.name == "annotation" && annotation.arguments.length != 0)
				fail("E1024", "@:annotation does not accept arguments", annotation.span);

	static function isAnnotationScalar(type:CompilerType):Bool
		return switch type {
			case TInt | TFloat | TString | TBool: true;
			case TNullable(element): isAnnotationScalar(element);
			case TAbstract(_, _, representation): isAnnotationScalar(representation);
			case _: false;
		};

	static function isBuiltInMetadata(name:String):Bool
		return switch name {
			case "access" | "allow" | "annotation" | "arrayAccess" | "cNative" | "discoverMethods" | "expose" | "flat" | "forward" | "from" | "hiddenUnless" |
				"hlNative" | "hlType" | "id" | "isVar" | "keep" | "metadata" | "noCompletion" | "noInline" | "op" | "optional" | "portable" |
				"privateAccess" | "pure" | "renamedFrom" | "repr" | "value" | "wire": true;
			case _: false;
		};

	function buildNativeTypeDescriptor(resolved:CompilerType):Null<NativeTypeDescriptorData> {
		var name = descriptorRecordName(resolved);
		if (name == null)
			return null;
		var declaration = session.classDecls.get(name);
		if (declaration == null)
			return null;
		var root = descriptorNode(name, resolved, null, [for (metadata in declaration.metadata) metadata.name], typedMetadata(declaration.metadata), []),
			identity = SemanticSignature.type(resolved),
			sourceKind = descriptorSourceKind(declaration),
			interfaces = descriptorInterfaces(resolved);
		return {
			version: NativeTypeDescriptor.VERSION,
			name: root.name,
			type: root.type,
			sourceKind: sourceKind,
			interfaces: interfaces,
			flat: root.flat,
			portable: root.portable,
			size: root.size,
			alignment: root.alignment,
			annotations: root.annotations,
			annotationValues: root.annotationValues,
			fields: root.fields,
			arguments: root.arguments,
			hash: NativeTypeDescriptor.contentHash(identity, name, root.type, sourceKind, interfaces, root.flat, root.portable, root.size, root.alignment,
				root.annotations, root.annotationValues, root.fields, root.arguments)
		};
	}

	static function descriptorSourceKind(declaration:AstClass):String
		return if (declaration.isStruct == true) "struct" else if (hasCRepresentation(declaration)) "native-value" else "class";

	function descriptorInterfaces(type:CompilerType):Array<String> {
		var unique:Map<String, Bool> = [], values:Array<String> = [];
		for (interfaceType in session.declarations.inheritance.inheritedInterfaces(type)) {
			var identity = SemanticSignature.type(interfaceType);
			if (!unique.exists(identity)) {
				unique.set(identity, true);
				values.push(identity);
			}
		}
		values.sort(Reflect.compare);
		return values;
	}

	function descriptorNode(fieldName:String, type:CompilerType, offset:Null<Int>, annotations:Array<String>,
			annotationValues:Array<NativeTypeAnnotationData>, visiting:Array<String>,
			defaultValue:Null<NativeTypeDescriptorDefault> = null):NativeTypeDescriptorField {
		var name = descriptorRecordName(type),
			recursive = name != null && visiting.indexOf(name) >= 0,
			facts = StructProperties.evaluate(session.declarations, type),
			layout = facts.flat ? descriptorLayout(type) : null,
			nested = recursive || name == null ? [] : descriptorFields(name, visiting),
			arguments = descriptorArguments(type, visiting);
		return {
			name: fieldName,
			type: SemanticSignature.type(type),
			flat: facts.flat,
			portable: facts.portable,
			size: layout == null ? null : layout.size,
			alignment: layout == null ? null : layout.alignment,
			offset: offset,
			defaultValue: defaultValue,
			annotations: annotations,
			annotationValues: annotationValues,
			fields: nested,
			arguments: arguments,
			recursive: recursive
		};
	}

	function descriptorFields(name:String, visiting:Array<String>):Array<NativeTypeDescriptorField> {
		var declaration = session.classDecls.get(name);
		if (declaration == null)
			return [];
		var layout = session.nativeLayoutsByName.get(name),
			offsets:Map<String, Int> = [];
		if (layout != null)
			for (field in layout.fields)
				offsets.set(field.name, field.offset);
		var nestedVisiting = visiting.concat([name]),
			fields:Array<NativeTypeDescriptorField> = [];
		for (field in declaration.fields)
			if (!field.isStatic && descriptorFieldHasStorage(field) && field.type != null) {
				var fieldType = session.declarations.resolve(field.type, field.span, session.currentContext.typeSubstitutions),
					fieldAnnotations = [for (metadata in field.metadata) metadata.name],
					defaultValue = descriptorDefaultValue(name, field.name, fieldType, field.initializer, field.span);
				fields.push(descriptorNode(field.name, fieldType, offsets.get(field.name), fieldAnnotations, typedMetadata(field.metadata), nestedVisiting,
					defaultValue));
			}
		return fields;
	}

	function descriptorDefaultValue(owner:String, fieldName:String, type:CompilerType, initializer:Null<AstExpression>,
			span:SourceSpan):Null<NativeTypeDescriptorDefault> {
		if (initializer == null)
			return null;
		var value = descriptorDefaultConstant(type, initializer);
		if (value == null) {
			var reason = switch initializer {
				case NullLiteral(_) if (!isNullableDefaultType(type)): "null requires an explicitly nullable field type";
				case _:
					var nativeInteger = switch type {
						case TNativeScalar(name): {name: name};
						case _: null;
					};
					var integer = integerDefaultLiteral(initializer);
					if (nativeInteger != null
						&& integer != null
						&& !NativeTypeDescriptor.integerDefaultFits('native-scalar:${nativeInteger.name}',
							integer)) 'integer literal $integer is outside the range of native scalar ${nativeInteger.name}' else
						"only scalar literal defaults are supported; executable and computed defaults are unsupported";
			};
			fail("E1024", 'Native descriptor field "$owner.$fieldName" has an unsupported default: $reason', span);
		}
		var valueType = switch value {
			case IntValue(_): "Int";
			case FloatValue(_): "Float";
			case StringValue(_): "String";
			case BoolValue(_): "Bool";
			case NullValue: "Null";
		};
		return {type: valueType, value: value};
	}

	function descriptorDefaultConstant(type:CompilerType, initializer:AstExpression):Null<NativeTypeAnnotationValue>
		return switch type {
			case TNullable(element):
				switch initializer {
					case NullLiteral(_): NullValue;
					case _: descriptorDefaultConstant(element, initializer);
				};
			case TAbstract(_, _, representation): descriptorDefaultConstant(representation, initializer);
			case TNativeScalar("f32"):
				var value = floatDefaultLiteral(initializer);
				if (value == null) null; else {
					var rounded = NativeTypeDescriptor.float32DefaultValue(value);
					if (rounded == null)
						null
					else
						FloatValue(cast rounded);
				};
			case TNativeScalar(name): var integer = integerDefaultLiteral(initializer); integer == null || !NativeTypeDescriptor.integerDefaultFits('native-scalar:$name',
					integer) ? null : IntValue(integer);
			case TInt:
				switch initializer {
					case IntegerLiteral(value, _): IntValue(value);
					case Negate(IntegerLiteral(value, _), _): IntValue(-value);
					case _: null;
				};
			case TFloat: var value = floatDefaultLiteral(initializer); value == null || !Math.isFinite(value) ? null : FloatValue(value);
			case TString:
				switch initializer {
					case StringLiteral(value, _): StringValue(value);
					case _: null;
				};
			case TBool:
				switch initializer {
					case BoolLiteral(value, _): BoolValue(value);
					case _: null;
				};
			case _: null;
		};

	static function floatDefaultLiteral(initializer:AstExpression):Null<Float>
		return switch initializer {
			case IntegerLiteral(value, _): value;
			case FloatLiteral(value, _): value;
			case Negate(IntegerLiteral(value, _), _): -value;
			case Negate(FloatLiteral(value, _), _): -value;
			case _: null;
		};

	static function integerDefaultLiteral(initializer:AstExpression):Null<Int>
		return switch initializer {
			case IntegerLiteral(value, _): value;
			case Negate(IntegerLiteral(value, _), _): -value;
			case _: null;
		};

	static function isNullableDefaultType(type:CompilerType):Bool
		return switch type {
			case TNullable(_): true;
			case TAbstract(_, _, representation): isNullableDefaultType(representation);
			case _: false;
		};

	function descriptorArguments(type:CompilerType, visiting:Array<String>):Array<NativeTypeDescriptorField> {
		var arguments:Array<{name:String, type:CompilerType}> = switch type {
			case TNullable(element) | TArray(element) | TIterator(element): [{name: "element", type: element}];
			case TMap(key, value): [{name: "key", type: key}, {name: "value", type: value}];
			case TFunction(parameters, result):
				[
					for (index in 0...parameters.length)
						{name: 'parameter$index', type: parameters[index]}
				].concat([{name: "result", type: result}]);
			case TAbstract(_, parameters, representation):
				var values = [
					for (index in 0...parameters.length)
						{name: 'argument$index', type: parameters[index]}
				];
				if (parameters.length == 0 && SemanticSignature.type(representation) != SemanticSignature.type(type))
					values.push({name: "representation", type: representation});
				values;
			case TInstance(_, _, parameters): [
					for (index in 0...parameters.length)
						{name: 'argument$index', type: parameters[index]}
				];
			case _: [];
		};
		return [
			for (argument in arguments)
				descriptorNode(argument.name, argument.type, null, [], [], visiting)
		];
	}

	function descriptorLayout(type:CompilerType):Null<{size:Int, alignment:Int}> {
		var recordName = descriptorRecordName(type);
		if (recordName != null) {
			var record = session.nativeLayoutsByName.get(recordName);
			return record == null ? null : {size: record.size, alignment: record.alignment};
		}
		var nativeType:compiler.ffi.HxiModel.HxiType;
		try {
			nativeType = NativeLayout.fieldType(type);
		} catch (_:Dynamic) {
			return null;
		}
		var layout = HxiAbi.forTarget(session.nativeAbiTarget).layout(nativeType);
		return layout == null ? null : {size: layout.size, alignment: layout.align};
	}

	function descriptorRecordName(type:CompilerType):Null<String>
		return switch type {
			case TInstance(NominalKind.NativeValue, name, _): name;
			case TInstance(NominalKind.Class, name, _) if (isStructDeclaration(session.classDecls.get(name))): name;
			case TNullable(element): descriptorRecordName(element);
			case TAbstract(_, _, representation): descriptorRecordName(representation);
			case _: null;
		};

	static function isStructDeclaration(declaration:Null<compiler.syntax.Ast.AstClass>):Bool
		return declaration != null && (declaration.isStruct == true || hasCRepresentation(declaration));

	static function descriptorFieldHasStorage(field:compiler.syntax.Ast.AstField):Bool {
		if (descriptorHasDirectAccess(field.readAccess) || descriptorHasDirectAccess(field.writeAccess))
			return true;
		for (metadata in field.metadata)
			if (metadata.name == "isVar")
				return true;
		return false;
	}

	static function descriptorHasDirectAccess(access:Null<compiler.syntax.Ast.AstFieldAccess>):Bool
		return switch access {
			case compiler.syntax.Ast.AstFieldAccess.GetAccess | compiler.syntax.Ast.AstFieldAccess.SetAccess | compiler.syntax.Ast.AstFieldAccess.NeverAccess: false;
			case _: true;
		};

	static function nullableInteger(value:Null<Int>, span:SourceSpan):AstExpression
		return value == null ? NullLiteral(span) : IntegerLiteral(cast value, span);

	static function stringArray(values:Array<String>, span:SourceSpan):AstExpression
		return ArrayLiteral([for (value in values) StringLiteral(value, span)], span);

	static function descriptorFieldExpression(field:NativeTypeDescriptorField, span:SourceSpan):AstExpression
		return ObjectLiteral([
			objectField("name", StringLiteral(field.name, span), span),
			objectField("type", StringLiteral(field.type, span), span),
			objectField("flat", BoolLiteral(field.flat, span), span),
			objectField("portable", BoolLiteral(field.portable, span), span),
			objectField("size", nullableInteger(field.size, span), span),
			objectField("alignment", nullableInteger(field.alignment, span), span),
			objectField("offset", nullableInteger(field.offset, span), span),
			objectField("defaultValue", descriptorDefaultExpression(field.defaultValue, span), span),
			objectField("annotations", stringArray(field.annotations, span), span),
			objectField("annotationValues", annotationValuesExpression(field.annotationValues, span), span),
			objectField("fields", ArrayLiteral([for (child in field.fields) descriptorFieldExpression(child, span)], span), span),
			objectField("arguments", ArrayLiteral([for (argument in field.arguments) descriptorFieldExpression(argument, span)], span), span),
			objectField("recursive", BoolLiteral(field.recursive, span), span)
		], span);

	static function descriptorDefaultExpression(value:Null<NativeTypeDescriptorDefault>, span:SourceSpan):AstExpression
		return if (value == null) NullLiteral(span) else ObjectLiteral([
			objectField("type", StringLiteral(value.type, span), span),
			objectField("value", annotationConstantExpression(value.value, span), span)
		], span);

	static function annotationValuesExpression(values:Array<NativeTypeAnnotationData>, span:SourceSpan):AstExpression
		return ArrayLiteral([
			for (annotation in values)
				ObjectLiteral([
					objectField("name", StringLiteral(annotation.name, span), span),
					objectField("arguments", ArrayLiteral([
						for (argument in annotation.arguments)
							ObjectLiteral([
								objectField("name", StringLiteral(argument.name, span), span),
								objectField("type", StringLiteral(argument.type, span), span),
								objectField("value", annotationConstantExpression(argument.value, span), span)
							], span)
					], span), span)
				], span)
		], span);

	static function annotationConstantExpression(value:NativeTypeAnnotationValue, span:SourceSpan):AstExpression
		return switch value {
			case IntValue(value): IntegerLiteral(value, span);
			case FloatValue(value): FloatLiteral(value, span);
			case StringValue(value): StringLiteral(value, span);
			case BoolValue(value): BoolLiteral(value, span);
			case NullValue: NullLiteral(span);
		};

	static function objectField(name:String, value:AstExpression, span:SourceSpan):AstObjectField
		return {name: name, value: value, span: span};

	public function typeObjectLiteral(fields:Array<AstObjectField>, span:SourceSpan, scope:Scope, expectedType:Null<CompilerType>):TypedExpression {
		var objectExpected = objectLiteralExpectation(expectedType),
			expectedFields = anonymousFields(objectExpected),
			seen:Map<String, Bool> = [],
			typedFields:Array<TypedObjectField> = [];
		for (field in fields) {
			if (seen.exists(field.name))
				fail("E1001", 'Duplicate object field "${field.name}"', field.span);
			seen.set(field.name, true);
			var expectedField = anonymousField(expectedFields, field.name);
			if (expectedFields != null && expectedField == null)
				fail("E1002", 'Unexpected object field "${field.name}"', field.span);
			var value = typeExpressionCallback(field.value, scope, expectedField == null ? null : expectedField.type, false);
			if (expectedField != null)
				value = coerce(value, expectedField.type, 'object field "${field.name}"', "E1002");
			else if (value.type == TNull)
				value = coerce(value, TDynamic, 'object field "${field.name}"', "E1002");
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
					{
						name: field.name,
						type: field.value.type,
						optional: false,
						isFinal: false
					}
			];
			inferred.sort(function(left, right) return Reflect.compare(left.name, right.name));
			resolvedResult = TAnonymous(anonymousTypeName(inferred), inferred);
		} else
			resolvedResult = objectExpected;
		var typeName = switch resolvedResult {
			case TAnonymous(name, _): name;
			default: "";
		};
		var isDynamic = objectExpected == null && isDynamicExpectation(expectedType);
		// Targets without native dynamic objects (Wasm) allocate the stdlib's dynamic object class.
		if (isDynamic)
			session.runtimeDependencyTracker.record(session.currentContext.name, PlatformAbi.DYNAMIC_OBJECT_CLASS);
		anonymousTypeRegistry.register(resolvedResult);
		return new TypedExpression(TObjectLiteral(typeName, typedFields, isDynamic), isDynamic ? TDynamic : resolvedResult, span);
	}

	static function isDynamicExpectation(type:Null<CompilerType>):Bool
		return switch type {
			case TDynamic: true;
			case TNullable(element): isDynamicExpectation(element);
			default: false;
		};

	public function typeArrayLiteral(values:Array<AstExpression>, span:SourceSpan, scope:Scope, expectedType:Null<CompilerType>):TypedExpression {
		var expectedMap = mapExpectation(expectedType);
		if (values.length == 0 && expectedMap != null)
			return new TypedExpression(TMapLiteral([]), TMap(expectedMap.key, expectedMap.value), span);
		// In a Dynamic context the elements still decide the type, as they would anywhere else ([new Child()] is an
		// Array<Child>, which does not convert to Array<Base>); only elements with no common type, or none, make it Dynamic.
		var dynamicContext = isDynamicExpectation(expectedType);
		var expectedElement = dynamicContext ? null : arrayElementExpectation(expectedType);
		if (values.length == 0 && expectedElement == null) {
			if (!dynamicContext)
				fail("E1003", "Empty array literal requires an expected element type", span);
			expectedElement = TDynamic;
		}
		var typedValues:Array<TypedExpression> = [],
			elementType = dynamicContext && values.length == 0 ? TDynamic : expectedElement;
		for (value in values) {
			var typedValue = typeExpressionCallback(value, scope, elementType == TNull || dynamicContext ? null : elementType, false);
			if (expectedElement == null) {
				var joined = elementType == null ? typedValue.type : commonConditionalType(elementType, typedValue.type);
				if (joined == null && dynamicContext)
					joined = TDynamic;
				if (joined == null)
					fail("E1003", "Array elements have incompatible types; use Array<Dynamic> for a mixed-type array", typedValue.span);
				// Dynamic permits mixed storage, but homogeneous arrays keep their exact element contract.
				elementType = joined == null ? TDynamic : joined;
			}
			typedValues.push(typedValue);
		}
		if (elementType == null)
			throw "Array element type was not resolved";
		// Decide storage before coercing any element: a later Float or nullable value can widen it.
		typedValues = [for (value in typedValues) coerce(value, elementType, "array element", "E1003")];
		return new TypedExpression(TArrayLiteral(typedValues), TArray(elementType), span);
	}

	public function typeMapLiteral(entries:Array<AstMapEntry>, span:SourceSpan, scope:Scope, expectedType:Null<CompilerType>):TypedExpression {
		var expected = mapExpectation(expectedType),
			keyType = expected == null ? null : expected.key,
			valueType = expected == null ? null : expected.value,
			typedEntries:Array<TypedMapEntry> = [];
		for (entry in entries) {
			var key = typeExpressionCallback(entry.key, scope, keyType, false),
				value = typeExpressionCallback(entry.value, scope, valueType, false),
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
			typedEntries.push({key: coerce(key, resolvedKey, "map key", "E1003"), value: coerce(value, resolvedValue, "map value", "E1003")});
		}
		if (keyType == null || valueType == null)
			fail("E1003", "An empty map literal requires an expected key and value type", span);
		if (session.mapName(keyType, valueType) == null)
			fail("E1016", "This map key/value type has no compiler-owned runtime ABI", span);
		return new TypedExpression(TMapLiteral(typedEntries), TMap(keyType, valueType), span);
	}

	/** `0...held.length`, the indices of the array a comprehension over `index => element` holds. */
	static function indexRange(held:String, span:SourceSpan):AstExpression
		return Range(IntegerLiteral(0, span), Member(Variable(held, span), "length", span), span);

	/**
	 * `expression` evaluated with `element` bound to `held[index]`. A nested `for` is flattened into its parent, so the
	 * binding goes into each part of that inner comprehension rather than around it, which would hide it.
	 */
	static function bindElement(element:String, held:String, index:String, expression:AstExpression, span:SourceSpan):AstExpression
		return switch expression {
			case ArrayComprehension(innerKey, innerValue, iterable, filter, value, true, innerSpan):
				ArrayComprehension(innerKey, innerValue, bindElement(element, held, index, iterable, span), bindOptional(element, held, index, filter, span),
					bindElement(element, held, index, value, span), true, innerSpan);
			default:
				BlockExpression([
					VarDeclaration(element, null, Index(Variable(held, span), Variable(index, span), span), span)
				], expression, span);
		};

	static function bindOptional(element:String, held:String, index:String, expression:Null<AstExpression>, span:SourceSpan):Null<AstExpression>
		return expression == null ? null : bindElement(element, held, index, expression, span);

	public function typeArrayComprehension(keyName:String, valueName:Null<String>, iterable:AstExpression, predicate:Null<AstExpression>, value:AstExpression,
			flattened:Bool, span:SourceSpan, scope:Scope, expectedType:Null<CompilerType>):TypedExpression {
		var typedIterable = unwrapNullable(typeExpressionCallback(iterable, scope, null, false));
		if (IterationProtocol.structuralIterator(typedIterable.type))
			IterationProtocol.invalidateEffects(session, scope);
		var forwardedArray = AbstractForwarding.arrayStorage(session, typedIterable.type, "iterator");
		if (forwardedArray != null)
			typedIterable = session.representation.boundaryCast(typedIterable, forwardedArray);
		// Haxe iterates any class instance or structure through its `iterator()` method.
		if (valueName == null
			&& IterationProtocol.structuralIterator(typedIterable.type)
			&& IterationProtocol.method(session.declarations, typedIterable.type, "iterator") != null)
			typedIterable = unwrapNullable(IterationProtocol.call(session, typedIterable, "iterator"));
		var originalIterable = typedIterable,
			loopScope = new Scope(scope),
			keyType:Null<CompilerType> = null,
			bodyExpressions = predicate == null ? [value] : [predicate, value];
		LoopFlow.enterExpressions(session, scope, bodyExpressions, span, valueName == null ? [keyName] : [keyName, valueName]);
		switch typedIterable.type {
			case TArray(element):
				if (valueName != null) {
					// `[for (index => element in array) ...]` loops over the indices and binds each element.
					var held = "__haxeon_array" + span.start;
					return typeExpressionCallback(BlockExpression([VarDeclaration(held, null, iterable, span)],
						ArrayComprehension(keyName, null, indexRange(held, span), bindOptional(valueName, held, keyName, predicate, span),
							bindElement(valueName, held, keyName, value, span), flattened, span),
						span),
						scope, expectedType, false);
				}
				keyType = element;
			case TIterator(element):
				if (valueName != null)
					fail("E1014", "Key/value array comprehension requires a Map", span);
				keyType = element;
			case TRange:
				if (valueName != null)
					fail("E1014", "Key/value array comprehension requires a Map", span);
				keyType = TInt;
			case TMap(key, mapValue):
				if (session.mapName(key, mapValue) == null)
					fail("E1016", "This map key/value type has no compiler-owned runtime ABI", span);
				keyType = valueName == null ? mapValue : key;
				if (valueName == null)
					typedIterable = new TypedExpression(TCollectionCall(typedIterable, "values", []), TArray(mapValue), span);
			default:
				keyType = valueName == null ? IterationProtocol.element(session.declarations, typedIterable.type, false) : null;
				if (keyType == null)
					fail("E1014", "Array comprehension requires an iterable or an iterator with hasNext():Bool and next()", span);
		}
		if (keyType == null)
			throw "Array comprehension item type was not resolved";
		loopScope.define(keyName, keyType, span);
		if (valueName != null)
			switch originalIterable.type {
				case TMap(_, mapValue):
					loopScope.define(valueName, mapValue, span);
				default:
			}
		var map = valueName == null ? CallResolver.mapKeyIteratorSource(originalIterable) : null;
		if (map == null)
			map = valueName == null ? FlowAnalysis.mapKeySource(originalIterable, scope) : null;
		if (valueName == null
			&& !AstScan.mayRemoveMapEntries([for (expression in bodyExpressions) Expression(expression, span)], keyName)) {
			if (map != null) {
				var key = new TypedExpression(TLocal(loopScope.requireId(keyName)), keyType, span),
					entryPath = FlowAnalysis.mapEntryPath(map, key);
				if (entryPath != null)
					switch map.type {
						case TMap(_, value):
							loopScope.refineExpression(entryPath, value, FlowAnalysis.entryFactsSurviveCalls(scope, map));
						default:
					}
			}
		}
		var typedCondition = predicate == null ? null : typeExpressionCallback(predicate, loopScope, TBool, false);
		if (typedCondition != null && typedCondition.type != TBool)
			fail("E1004", "Array comprehension condition must be Bool", span);
		// The value is only computed where the condition holds, so it sees what the condition proves.
		var valueScope = typedCondition == null ? loopScope : FlowAnalysis.narrowedScope(loopScope, typedCondition, true, session.isPureCall);
		var expectedElement = arrayElementExpectation(expectedType),
			typedValue = typeExpressionCallback(value, valueScope, expectedElement, false),
			flattenedElement = switch typedValue.expression {
				case TArrayComprehension(_, _, _, _, _, true): arrayElementType(typedValue.type, span);
				case _: switch value {
						case ArrayComprehension(_, _, _, _, _, true, _): arrayElementType(typedValue.type, span);
						case _: null;
					}
			},
			elementType = expectedElement == null ? (flattenedElement == null ? typedValue.type : flattenedElement) : expectedElement;
		if (flattenedElement == null)
			typedValue = coerce(typedValue, elementType, "array comprehension value", "E1003");
		if (IterationProtocol.structuralIterator(typedIterable.type)) {
			var resultType = TArray(elementType),
				resultName = "$comprehension-result:" + span.start;
			var result = new TypedExpression(TLocal(resultName), resultType, span);
			var append:TypedStatement = TExpression(new TypedExpression(TCollectionCall(result, "push", [typedValue]), TInt, span), span);
			if (flattenedElement != null) {
				var inner = "$comprehension-item:" + span.start;
				append = TForIn(inner, null, typedValue, [
					TExpression(new TypedExpression(TCollectionCall(result, "push", [new TypedExpression(TLocal(inner), elementType, span)]), TInt, span), span)
				], span);
			}
			return structuralComprehension(typedIterable, loopScope.requireId(keyName), typedCondition, append, resultName,
				new TypedExpression(TArrayLiteral([]), resultType, span), result, span);
		}
		return new TypedExpression(TArrayComprehension(loopScope.requireId(keyName), valueName == null ? null : loopScope.requireId(valueName),
			valueName == null ? typedIterable : originalIterable, typedCondition, typedValue, flattened),
			TArray(elementType), span, false, map);
	}

	public function typeMapComprehension(keyName:String, valueName:Null<String>, iterable:AstExpression, predicate:Null<AstExpression>, key:AstExpression,
			value:AstExpression, span:SourceSpan, scope:Scope, expectedType:Null<CompilerType>):TypedExpression {
		var typedIterable = unwrapNullable(typeExpressionCallback(iterable, scope, null, false));
		if (IterationProtocol.structuralIterator(typedIterable.type))
			IterationProtocol.invalidateEffects(session, scope);
		if (valueName == null
			&& IterationProtocol.structuralIterator(typedIterable.type)
			&& IterationProtocol.method(session.declarations, typedIterable.type, "iterator") != null)
			typedIterable = unwrapNullable(IterationProtocol.call(session, typedIterable, "iterator"));
		var originalIterable = typedIterable,
			loopScope = new Scope(scope),
			itemType:Null<CompilerType> = null;
		LoopFlow.enterExpressions(session, scope, predicate == null ? [key, value] : [predicate, key, value], span,
			valueName == null ? [keyName] : [keyName, valueName]);
		switch typedIterable.type {
			case TArray(element):
				if (valueName != null) {
					var held = "__haxeon_array" + span.start;
					return typeExpressionCallback(BlockExpression([VarDeclaration(held, null, iterable, span)],
						MapComprehension(keyName, null, indexRange(held, span), bindOptional(valueName, held, keyName, predicate, span),
							bindElement(valueName, held, keyName, key, span), bindElement(valueName, held, keyName, value, span), span),
						span),
						scope, expectedType, false);
				}
				itemType = element;
			case TIterator(element):
				if (valueName != null)
					fail("E1014", "Key/value map comprehension requires a Map", span);
				itemType = element;
			case TRange:
				if (valueName != null)
					fail("E1014", "Key/value map comprehension requires a Map", span);
				itemType = TInt;
			case TMap(mapKey, mapValue):
				if (session.mapName(mapKey, mapValue) == null)
					fail("E1016", "This map key/value type has no compiler-owned runtime ABI", span);
				itemType = valueName == null ? mapValue : mapKey;
				if (valueName == null)
					typedIterable = new TypedExpression(TCollectionCall(typedIterable, "values", []), TArray(mapValue), span);
			default:
				itemType = valueName == null ? IterationProtocol.element(session.declarations, typedIterable.type, false) : null;
				if (itemType == null)
					fail("E1014", "Map comprehension requires an iterable or an iterator with hasNext():Bool and next()", span);
		}
		if (itemType == null)
			throw "Map comprehension item type was not resolved";
		loopScope.define(keyName, itemType, span);
		if (valueName != null)
			switch originalIterable.type {
				case TMap(_, mapValue):
					loopScope.define(valueName, mapValue, span);
				default:
			}
		var typedCondition = predicate == null ? null : typeExpressionCallback(predicate, loopScope, TBool, false);
		if (typedCondition != null && typedCondition.type != TBool)
			fail("E1004", "Map comprehension condition must be Bool", span);
		// The entry is only computed where the condition holds, so it sees what the condition proves.
		var entryScope = typedCondition == null ? loopScope : FlowAnalysis.narrowedScope(loopScope, typedCondition, true, session.isPureCall);
		var expected = mapExpectation(expectedType),
			typedKey = typeExpressionCallback(key, entryScope, expected == null ? null : expected.key, false),
			typedValue = typeExpressionCallback(value, entryScope, expected == null ? null : expected.value, false),
			resultKey = expected == null ? typedKey.type : expected.key,
			resultValue = expected == null ? typedValue.type : expected.value;
		typedKey = coerce(typedKey, resultKey, "map comprehension key", "E1003");
		typedValue = coerce(typedValue, resultValue, "map comprehension value", "E1003");
		if (session.mapName(resultKey, resultValue) == null)
			fail("E1016", "This map key/value type has no compiler-owned runtime ABI", span);
		if (IterationProtocol.structuralIterator(typedIterable.type)) {
			var resultType = TMap(resultKey, resultValue),
				resultName = "$comprehension-result:" + span.start;
			var result = new TypedExpression(TLocal(resultName), resultType, span);
			return structuralComprehension(typedIterable, loopScope.requireId(keyName), typedCondition, TMapAssign(result, typedKey, typedValue, span),
				resultName, new TypedExpression(TMapLiteral([]), resultType, span), result, span);
		}
		return new TypedExpression(TMapComprehension(loopScope.requireId(keyName), valueName == null ? null : loopScope.requireId(valueName),
			valueName == null ? typedIterable : originalIterable, typedCondition, typedKey, typedValue),
			TMap(resultKey, resultValue), span);
	}

	function structuralComprehension(iterable:TypedExpression, item:String, condition:Null<TypedExpression>, append:TypedStatement, resultName:String,
			initial:TypedExpression, result:TypedExpression, span:SourceSpan):TypedExpression {
		var held = "$comprehension-iterator:" + span.start;
		var receiver = new TypedExpression(TLocal(held), iterable.type, span);
		var body = [
			TVar(item, IterationProtocol.call(session, receiver, "next"), span),
			condition == null ? append : TIf(condition, [append], [], span)
		];
		return new TypedExpression(TBlockExpression([
			TVar(resultName, initial, span),
			TVar(held, iterable, span),
			TWhile(IterationProtocol.call(session, receiver, "hasNext"), body, span)
		], result), result.type, span);
	}

	public function typeRange(start:AstExpression, rangeEnd:AstExpression, span:SourceSpan, scope:Scope):TypedExpression {
		var typedStart = typeExpressionCallback(start, scope, TInt, false),
			typedEnd = typeExpressionCallback(rangeEnd, scope, TInt, false);
		if (typedStart.type != TInt || typedEnd.type != TInt)
			fail("E1014", "Range bounds must be Int values", span);
		return new TypedExpression(TRange(typedStart, typedEnd), TRange, span);
	}

	public function typeIndex(array:AstExpression, offset:AstExpression, span:SourceSpan, scope:Scope):TypedExpression {
		var typedArray = unwrapNullable(typeExpressionCallback(array, scope, null, false)),
			typedIndex = typeExpressionCallback(offset, scope, null, false);
		var forwardedArray = AbstractForwarding.arrayStorage(session, typedArray.type, null);
		if (forwardedArray != null)
			typedArray = session.representation.boundaryCast(typedArray, forwardedArray);
		return switch typedArray.type {
			case TMap(key, value):
				if (session.mapName(key, value) == null)
					fail("E1016", "This map key/value type has no compiler-owned runtime ABI", span);
				var typedKey = coerce(typedIndex, key, "map key", "E1002"),
					entryPath = FlowAnalysis.mapEntryPath(typedArray, typedKey),
					refined = entryPath == null ? null : scope.resolveExpression(entryPath);
				new TypedExpression(TMapGet(typedArray, typedKey), refined == null ? CallResolver.nullableMapValue(value) : refined, span);
			default:
				if (typedIndex.type == TNever)
					typedIndex = coerce(typedIndex, TInt, "array index", "E1014");
				if (typedIndex.type != TInt)
					fail("E1014", "Array index must be Int", typedIndex.span);
				var element = arrayElementType(typedArray.type, span);
				new TypedExpression(TIndex(typedArray, typedIndex), element, span);
		};
	}

	public function typeNewArray(element:AstType, length:AstExpression, span:SourceSpan, scope:Scope, lowerType:LowerExpressionTypeCallback):TypedExpression {
		var typedLength = typeExpressionCallback(length, scope, null, false);
		if (typedLength.type != TInt)
			fail("E1014", "Array length must be Int", typedLength.span);
		var loweredElement = lowerType(element);
		return new TypedExpression(TNewArray(loweredElement, typedLength), TArray(loweredElement), span);
	}

	public function typeNewMap(key:AstType, value:AstType, span:SourceSpan, lowerType:LowerExpressionTypeCallback):TypedExpression {
		var loweredKey = lowerType(key), loweredValue = lowerType(value);
		if (session.mapName(loweredKey, loweredValue) == null)
			fail("E1016", "This map key/value type has no compiler-owned runtime ABI", span);
		return new TypedExpression(TNewMap(loweredKey, loweredValue), TMap(loweredKey, loweredValue), span);
	}

	public function typeSwitchExpression(expression:AstExpression, cases:Array<AstSwitchExpressionCase>, defaultExpression:Null<AstExpression>,
			span:SourceSpan, scope:Scope, expectedType:Null<CompilerType>):TypedExpression {
		var typedSubject = typeExpressionCallback(expression, scope, null, false);
		if (!sameType(typedSubject.type, TInt)
			&& !sameType(typedSubject.type, TString)
			&& !isNullableString(typedSubject.type)
			&& !isArraySwitchable(typedSubject.type)
			&& !switchRules.isEnum(typedSubject.type))
			fail("E1019", "Switch requires an Int, String, array, or enum value", typedSubject.span);
		var typedCases:Array<TypedSwitchExpressionCase> = [],
			deferredCaseResults:Map<Int, {expression:AstExpression, scope:Scope}> = [],
			deferredDefault:Null<{expression:AstExpression, scope:Scope}> = null,
			seenCases:Map<String, Bool> = [],
			resultType = expectedType,
			defaultScope = new Scope(scope),
			typedDefault:Null<TypedExpression> = null;
		if (defaultExpression != null) {
			if (expectedType == null && isEmptyArrayLiteral(defaultExpression))
				deferredDefault = {expression: defaultExpression, scope: defaultScope};
			else
				typedDefault = typeExpressionCallback(defaultExpression, defaultScope, expectedType, false);
		}
		// A switch arm can need the inferred result type to resolve an enum constructor
		// (for example, `case A: SomeConstructor(...); default: value;`). Seed that
		// context from the fallback before typing the arms; the normal branch join below
		// still permits widening and nullable results.
		if (expectedType == null && typedDefault != null && typedDefault.type != TNever)
			resultType = typedDefault.type;
		for (switchCase in cases) {
			var caseScope = new Scope(scope),
				subjectBinding = switchRules.subjectBinding(switchCase.value, typedSubject.type, caseScope),
				isCatchAll = switchRules.catchAll(switchCase.value),
				arrayPattern = subjectBinding == null ? switchRules.arrayPattern(switchCase.value, typedSubject.type, caseScope) : null,
				pattern = subjectBinding == null
					&& arrayPattern == null ? switchRules.enumPattern(switchCase.value, typedSubject.type, caseScope) : null,
				typedValue = isCatchAll
					|| subjectBinding != null
					|| arrayPattern != null ? typedSubject : pattern == null ? coerce(EnumAbstractHints.typed(session,
						EnumAbstractHints.declaredAs(session, typedSubject), switchCase.value,
						() -> typeExpressionCallback(switchCase.value, scope, typedSubject.type, false)),
						typedSubject.type, "switch case", "E1019") : pattern.value;
			var parsedGuard = switchCase.guard,
				typedGuard = parsedGuard == null ? null : coerce(typeExpressionCallback(parsedGuard, caseScope, null, false), TBool, "switch guard", "E1003"),
				caseIndex = typedCases.length,
				typedResult:TypedExpression;
			if (typedGuard != null)
				caseScope = FlowAnalysis.narrowedScope(caseScope, typedGuard, true, session.isPureCall);
			if (expectedType == null && resultType == null && isEmptyArrayLiteral(switchCase.result)) {
				deferredCaseResults.set(caseIndex, {expression: switchCase.result, scope: caseScope});
				typedResult = new TypedExpression(TUnreachable, TNever, switchCase.span);
			} else
				typedResult = typeExpressionCallback(switchCase.result, caseScope, expectedType == null ? resultType : expectedType, false);
			var enumName:Null<String> = pattern == null ? null : pattern.enumName,
				constructorIndex = pattern == null ? -1 : pattern.index,
				predicates:Array<TypedSwitchPredicate> = pattern == null ? [] : pattern.predicates;
			if (expectedType == null && typedResult.type != TNever) {
				var joined = resultType == null ? typedResult.type : commonConditionalType(resultType, typedResult.type);
				if (joined == null)
					fail("E1003", "Switch branches must have matching types", switchCase.span);
				resultType = joined;
			}
			if (pattern == null) {
				var literal = switchRules.enumLiteral(typedValue);
				if (literal != null) {
					enumName = literal.name;
					constructorIndex = literal.index;
				}
			}
			var caseKey = arrayPattern == null ? switchRules.caseKey(typedValue, predicates) : switchRules.arrayPatternKey(arrayPattern);
			if (isCatchAll || subjectBinding != null)
				seenCases.set("$catchall", true);
			if (caseKey != null && typedGuard == null) {
				if (seenCases.exists(caseKey))
					fail("E1020", "Duplicate switch case", switchCase.span);
				seenCases.set(caseKey, true);
			}
			typedCases.push({
				value: typedValue,
				subjectBinding: subjectBinding,
				arrayPattern: arrayPattern,
				span: switchCase.span,
				isCatchAll: isCatchAll,
				guard: typedGuard,
				result: typedResult,
				enumName: enumName,
				constructorIndex: constructorIndex,
				bindings: pattern == null ? [] : pattern.bindings,
				predicates: predicates
			});
		}
		if (typedDefault != null && expectedType == null && typedDefault.type != TNever) {
			var joined = resultType == null ? typedDefault.type : commonConditionalType(resultType, typedDefault.type);
			if (joined == null)
				fail("E1003", "Switch branches must have matching types", span);
			resultType = joined;
		}
		if (resultType == null)
			fail("E1003", "Switch expression has no result branches", span);
		typedCases = [
			for (index in 0...typedCases.length) {
				var switchCase = typedCases[index],
					deferred = deferredCaseResults.get(index),
					result = deferred == null ? switchCase.result : typeExpressionCallback(deferred.expression, deferred.scope, resultType, false);
				{
					value: switchCase.value,
					subjectBinding: switchCase.subjectBinding,
					arrayPattern: switchCase.arrayPattern,
					span: switchCase.span,
					isCatchAll: switchCase.isCatchAll,
					guard: switchCase.guard,
					result: branchResult(result, resultType, "switch branch"),
					enumName: switchCase.enumName,
					constructorIndex: switchCase.constructorIndex,
					bindings: switchCase.bindings,
					predicates: switchCase.predicates
				}
			}
		];
		if (deferredDefault != null)
			typedDefault = typeExpressionCallback(deferredDefault.expression, deferredDefault.scope, resultType, false);
		if (typedDefault != null)
			typedDefault = branchResult(typedDefault, resultType, "switch branch");
		if (typedDefault == null && !switchRules.isEnum(typedSubject.type) && !seenCases.exists("$catchall"))
			fail("E1021", "Switch expression requires a default branch", span);
		if (switchRules.isEnum(typedSubject.type) && typedDefault == null && !seenCases.exists("$catchall")) {
			var resolvedEnumName = Std.string(switchRules.enumName(typedSubject.type)),
				missing:Array<String> = [],
				coverageCases:Array<TypedSwitchCoverageCase> = [
					for (switchCase in typedCases)
						{
							constructorIndex: switchCase.constructorIndex,
							subjectBinding: switchCase.subjectBinding,
							isCatchAll: switchCase.isCatchAll,
							guard: switchCase.guard,
							predicates: switchCase.predicates
						}
				];
			if (session.enumDecls.exists(resolvedEnumName)) {
				var enumDecl = session.enumDecls.get(resolvedEnumName);
				for (index in 0...enumDecl.cases.length)
					if (!seenCases.exists('enum:$resolvedEnumName:$index')
						&& !switchRules.enumCaseCovered(typedSubject.type, index, coverageCases))
						missing.push(enumDecl.cases[index].name);
			}
			if (switchRules.isNullableEnum(typedSubject.type) && !seenCases.exists("null"))
				missing.push("null");
			if (missing.length > 0)
				fail("E1021", 'Enum switch is missing cases: ${missing.join(", ")}', span);
		}
		return new TypedExpression(TSwitchExpression(typedSubject, typedCases, typedDefault), resultType, span);
	}

	static function isEmptyArrayLiteral(expression:AstExpression):Bool
		return switch expression {
			case ArrayLiteral(values, _): values.length == 0;
			default: false;
		};

	static function isNullableString(type:CompilerType):Bool
		return switch type {
			case TNullable(TString): true;
			default: false;
		};

	static function isArraySwitchable(type:CompilerType):Bool
		return switch type {
			case TArray(_): true;
			default: false;
		};

	public function typeConditional(predicate:AstExpression, whenTrue:AstExpression, whenFalse:AstExpression, span:SourceSpan, scope:Scope,
			expectedType:Null<CompilerType>, contextualExpressionType:ContextualExpressionTypeCallback):TypedExpression {
		var typedCondition = typeExpressionCallback(predicate, scope, TBool, false);
		if (!sameType(typedCondition.type, TBool))
			fail("E1011", "Conditional expression requires a Bool condition", span);
		var trueScope = FlowAnalysis.narrowedScope(scope, typedCondition, true, session.isPureCall),
			falseScope = FlowAnalysis.narrowedScope(scope, typedCondition, false, session.isPureCall),
			contextualType = expectedType;
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
		// An empty literal takes its type from the other branch, whichever side it is on.
		var earlyFalse:Null<TypedExpression> = null;
		if (contextualType == null && isEmptyLiteral(whenTrue)) {
			earlyFalse = typeExpressionCallback(whenFalse, falseScope, null, false);
			if (earlyFalse.type != TNull && earlyFalse.type != TNever)
				contextualType = earlyFalse.type;
		}
		var typedTrue = typeExpressionCallback(whenTrue, trueScope, contextualType, false),
			branchExpected = expectedType == null
				&& typedTrue.type != TNull
				&& typedTrue.type != TNever ? (containsNullLiteral(whenFalse) ? CompilerType.TNullable(typedTrue.type) : typedTrue.type) : expectedType,
			typedFalse = earlyFalse != null ? earlyFalse : typeExpressionCallback(whenFalse, falseScope, branchExpected, false),
			resultType = expectedType == null ? commonConditionalType(typedTrue.type, typedFalse.type) : expectedType;
		if (resultType == null)
			fail("E1003", "Conditional branches must have matching types", span);
		typedTrue = branchResult(typedTrue, resultType, "conditional branch");
		typedFalse = branchResult(typedFalse, resultType, "conditional branch");
		return new TypedExpression(TConditional(typedCondition, typedTrue, typedFalse), resultType, span);
	}

	/** A branch in a Void context is evaluated for its effects and its value is discarded. */
	function branchResult(value:TypedExpression, resultType:CompilerType, context:String):TypedExpression {
		if (resultType != TVoid || value.type == TVoid || value.type == TNever)
			return coerce(value, resultType, context, "E1003");
		return new TypedExpression(TBlockExpression([TExpression(value, value.span)], new TypedExpression(TVoidLiteral, TVoid, value.span)), TVoid, value.span);
	}

	static function isEmptyLiteral(expression:AstExpression):Bool
		return switch expression {
			case ArrayLiteral(values, _): values.length == 0;
			case MapLiteral(entries, _): entries.length == 0;
			default: false;
		};

	public function typeCast(value:AstExpression, target:Null<AstType>, span:SourceSpan, scope:Scope, expectedType:Null<CompilerType>,
			lowerType:LowerExpressionTypeCallback):TypedExpression {
		var targetType = target == null ? expectedType : lowerType(target);
		if (targetType == null)
			fail("E1003", "Untyped cast requires an expected type", span);
		// An explicit type ascription guides its operand; an untyped cast separates source inference from its destination.
		return conversionResolver.adaptFunction(typeExpressionCallback(value, scope, target == null ? null : targetType, false), targetType, span);
	}

	/**
	 * An operator with a Dynamic operand: what the values are is only known when the program runs, so it calls
	 * `haxeon.DynamicOps` with every operand boxed. Null unless an operand is Dynamic and the others are numbers or
	 * Dynamic as well (or Strings, for the ordering operators).
	 */
	function dynamicOperation(name:String, operands:Array<TypedExpression>, result:CompilerType, span:SourceSpan,
			orderable:Bool = false):Null<TypedExpression> {
		var dynamicOperand = false;
		for (operand in operands)
			if (sameType(operand.type, TDynamic))
				dynamicOperand = true;
			else if (!isNumeric(operand.type) && !(orderable && sameType(operand.type, TString)))
				return null;
		if (!dynamicOperand)
			return null;
		session.runtimeDependencyTracker.record(session.currentContext.name, "haxeon.DynamicOps");
		var boxed = [for (operand in operands) coerce(operand, TDynamic, "dynamic operand", "E1010")];
		return new TypedExpression(TCall("haxeon.DynamicOps." + name, boxed), result, span);
	}

	public function negate(value:AstExpression, span:SourceSpan, scope:Scope, expectedType:Null<CompilerType>):TypedExpression {
		var typedValue = typeExpressionCallback(value, scope, expectedType == TInt64 ? TInt64 : null, false);
		var overloaded = callResolver.typeAbstractOperator("u-", [typedValue], span, scope);
		if (overloaded != null)
			return overloaded;
		var dynamicResult = dynamicOperation("neg", [typedValue], TFloat, span);
		if (dynamicResult != null)
			return dynamicResult;
		if (!isNumeric(typedValue.type))
			fail("E1010", "Numeric negation requires an Int, Int64, or Float operand", span);
		return new TypedExpression(TNegate(typedValue), typedValue.type, span);
	}

	public function logicalNot(value:AstExpression, span:SourceSpan, scope:Scope):TypedExpression {
		var typedValue = typeExpressionCallback(value, scope, null, false);
		if (!sameType(typedValue.type, TBool))
			fail("E1011", "Logical negation requires a Bool operand", span);
		return new TypedExpression(TNot(typedValue), TBool, span);
	}

	public function throwExpression(value:AstExpression, span:SourceSpan, scope:Scope):TypedExpression
		return new TypedExpression(TThrowExpression(typeExpressionCallback(value, scope, null, false)), TNever, span);

	public function postfixIncrement(target:AstExpression, delta:Int, span:SourceSpan, scope:Scope):TypedExpression {
		var typedTarget = typeExpressionCallback(target, scope, null, false);
		if (sameType(typedTarget.type, TDynamic))
			return dynamicPostfixIncrement(target, delta, span, scope);
		if (!sameType(typedTarget.type, TInt) && !sameType(typedTarget.type, TFloat))
			fail("E1018", "Postfix increment requires a numeric target", span);
		var operation:TypedExpressionKind = switch typedTarget.expression {
			case TLocal(name): TPostfixLocal(name, delta);
			case TCellLocal(name, cellClass): TPostfixCellLocal(name, cellClass, delta);
			case TCellCaptured(name, cellClass): TPostfixCellCaptured(name, cellClass, delta);
			case TStaticField(owner, name):
				FinalFieldRules.rejectStaticMutation(session, owner, name, span);
				TPostfixStaticField(owner, name, delta);
			case TField(object, name):
				switch object.type {
					case TAnonymous(_, fields):
						for (field in fields)
							if (field.name == name && field.isFinal)
								fail("E1024", 'Final anonymous field "$name" cannot be assigned', span);
					default:
				}
				FinalFieldRules.rejectInstanceMutation(session, object, name, span);
				TPostfixField(object, name, delta);
			case TIndex(array, index): TPostfixIndex(array, index, delta);
			default:
				fail("E1018", "Postfix increment target is not assignable", span);
				TPostfixLocal("", delta);
		};
		switch target {
			case Variable(name, _):
				scope.invalidateExpressionsForLocal(name);
			default:
		}
		return new TypedExpression(operation, typedTarget.type, span);
	}

	/**
	 * `target++` on a Dynamic value: the value is the old one, and the target becomes it plus (or minus) one:
	 * `{ var old = target; target = old + 1; old }`.
	 */
	function dynamicPostfixIncrement(target:AstExpression, delta:Int, span:SourceSpan, scope:Scope):TypedExpression {
		var old = "__haxeon_incremented", // Adding keeps an Int an Int; subtracting would give a Float, as `target -= 1` does.
			updated = Add(Variable(old, span), delta > 0 ? IntegerLiteral(1, span) : Negate(IntegerLiteral(1, span), span), span),
			store = switch target {
				case Variable(name, _): Assignment(name, updated, span);
				case Member(object, field, _): FieldAssignment(object, field, updated, span);
				default:
					fail("E1018", "Postfix increment target is not assignable", span);
					Assignment("", updated, span);
			};
		return typeExpressionCallback(BlockExpression([VarDeclaration(old, null, target, span), store], Variable(old, span), span), scope, null, false);
	}

	public static function containsNullLiteral(expression:AstExpression):Bool
		return switch expression {
			case NullLiteral(_): true;
			case Conditional(_, whenTrue, whenFalse, _): containsNullLiteral(whenTrue) || containsNullLiteral(whenFalse);
			default: false;
		};

	public function commonConditionalType(left:CompilerType, right:CompilerType):Null<CompilerType> {
		if (left == TNever)
			return right;
		if (right == TNever || sameType(left, right))
			return left;
		if ((left == TInt && right == TFloat) || (left == TFloat && right == TInt))
			return TFloat;
		// Dynamic holds any value, so joining with it is Dynamic. Assignability alone would pick the other side, since
		// Dynamic converts to anything implicitly, and the Dynamic values would then need a cast that can fail.
		if (left == TDynamic || right == TDynamic)
			return TDynamic;
		switch left {
			case TNull:
				return right == TVoid ? null : (isNullable(right) ? right : TNullable(right));
			case TNullable(inner) if (sameType(inner, right)):
				return TNullable(inner);
			default:
		}
		switch right {
			case TNull:
				return left == TVoid ? null : (isNullable(left) ? left : TNullable(left));
			case TNullable(inner) if (sameType(left, inner)):
				return TNullable(inner);
			default:
		}
		if (session.relations.isAssignable(left, right))
			return right;
		if (session.relations.isAssignable(right, left))
			return left;
		return null;
	}

	public function typeLiteral(expression:AstExpression, expectedType:Null<CompilerType>):TypedExpression
		return switch expression {
			case IntegerLiteral(value, span):
				var type = switch expectedType {
					case TInt64: TInt64;
					case TNativeScalar(name) if (name != "f32" && name != "f64"): expectedType;
					case _: TInt;
				};
				new TypedExpression(TIntLiteral(value), type, span);
			case FloatLiteral(value, span):
				var type = switch expectedType {
					case TNativeScalar("f32") | TNativeScalar("f64"): expectedType;
					case _: TFloat;
				};
				new TypedExpression(TFloatLiteral(value), type, span);
			case StringLiteral(value, span): new TypedExpression(TStringLiteral(value), TString, span);
			case BoolLiteral(value, span): new TypedExpression(TBoolLiteral(value), TBool, span);
			case NullLiteral(span): new TypedExpression(TNullLiteral, TNull, span);
			case Unreachable(span): new TypedExpression(TUnreachable, TNever, span);
			case EmptyExpression(span): new TypedExpression(TVoidLiteral, TVoid, span);
			case ErrorExpression(span): new TypedExpression(TNullLiteral, TDynamic, span);
			default: throw "ExpressionTyper.typeLiteral requires a literal expression";
		};

	public function arithmetic(a:AstExpression, b:AstExpression, scope:Scope, add:Bool, span:SourceSpan, expected:Null<CompilerType>):TypedExpression {
		var left = typeExpressionCallback(a, scope, null, false),
			right = typeExpressionCallback(b, scope, null, false);
		var overloaded = callResolver.typeAbstractOperator(add ? "+" : "-", [left, right], span, scope);
		if (overloaded != null)
			return overloaded;
		if (expected != null && isNumeric(expected)) {
			if (left.type == TDynamic)
				left = coerce(left, expected, "arithmetic operand", "E1010");
			if (right.type == TDynamic)
				right = coerce(right, expected, "arithmetic operand", "E1010");
		}
		if (left.type == TNever && isNumeric(right.type))
			left = coerce(left, right.type, "arithmetic operand", "E1009");
		if (right.type == TNever && isNumeric(left.type))
			right = coerce(right, left.type, "arithmetic operand", "E1009");
		if (add && (isStringOperand(left.type) || isStringOperand(right.type))) {
			left = stringify(left);
			right = stringify(right);
			return new TypedExpression(TAdd(left, right), TString, span);
		}
		var dynamicResult = dynamicOperation(add ? "add" : "sub", [left, right], add ? TDynamic : TFloat, span);
		if (dynamicResult != null)
			return dynamicResult;
		if (!isNumeric(left.type) || !isNumeric(right.type))
			fail("E1010", "Arithmetic requires matching numeric operands", span);
		var promoted = promoteNumericOperands(left, right, span);
		return new TypedExpression(add ? TAdd(promoted.left, promoted.right) : TSub(promoted.left, promoted.right), promoted.type, span);
	}

	public function logical(a:AstExpression, b:AstExpression, scope:Scope, and:Bool, span:SourceSpan):TypedExpression {
		var left = typeExpressionCallback(a, scope, null, false),
			rightScope = FlowAnalysis.narrowedScope(scope, left, and, session.isPureCall),
			right = typeExpressionCallback(b, rightScope, null, false);
		if (!sameType(left.type, TBool) || !sameType(right.type, TBool))
			fail("E1011", "Logical operators require Bool operands", span);
		return new TypedExpression(and ? TAnd(left, right) : TOr(left, right), TBool, span);
	}

	public function numeric(a:AstExpression, b:AstExpression, scope:Scope, operation:Int, span:SourceSpan):TypedExpression {
		var left = typeExpressionCallback(a, scope, null, false),
			right = typeExpressionCallback(b, scope, null, false);
		var overloaded = callResolver.typeAbstractOperator(operation == 2 ? "*" : "/", [left, right], span, scope);
		if (overloaded != null)
			return overloaded;
		var dynamicResult = dynamicOperation(operation == 2 ? "mul" : "div", [left, right], TFloat, span);
		if (dynamicResult != null)
			return dynamicResult;
		if (!isNumeric(left.type) || !isNumeric(right.type))
			fail("E1010", "Arithmetic requires matching numeric operands", span);
		var promoted = promoteNumericOperands(left, right, span, operation != 2);
		return new TypedExpression(operation == 2 ? TMul(promoted.left, promoted.right) : TDiv(promoted.left, promoted.right), promoted.type, span);
	}

	public function modulo(a:AstExpression, b:AstExpression, scope:Scope, span:SourceSpan):TypedExpression {
		var left = typeExpressionCallback(a, scope, null, false),
			right = typeExpressionCallback(b, scope, null, false);
		var overloaded = callResolver.typeAbstractOperator("%", [left, right], span, scope);
		if (overloaded != null)
			return overloaded;
		var dynamicResult = dynamicOperation("mod", [left, right], TFloat, span);
		if (dynamicResult != null)
			return dynamicResult;
		if (!isNumeric(left.type) || !isNumeric(right.type))
			fail("E1010", "Modulo requires matching numeric operands", span);
		var promoted = promoteNumericOperands(left, right, span);
		return sameType(promoted.type, TInt)
			|| sameType(promoted.type,
				TInt64) ? new TypedExpression(TMod(promoted.left, promoted.right), promoted.type,
				span) : new TypedExpression(TCall("__math_fmod", [promoted.left, promoted.right]), TFloat, span);
	}

	public function bitwise(a:AstExpression, b:AstExpression, scope:Scope, operation:Int, span:SourceSpan):TypedExpression {
		var left = typeExpressionCallback(a, scope, null, false),
			right = typeExpressionCallback(b, scope, null, false);
		var dynamicResult = dynamicOperation(["bitAnd", "bitXor", "bitOr", "shiftLeft", "shiftRight", "unsignedShiftRight"][operation], [left, right], TInt,
			span);
		if (dynamicResult != null)
			return dynamicResult;
		if (operation >= 3) {
			if (!sameType(left.type, TInt) && !sameType(left.type, TInt64))
				fail("E1010", "Shift operators require an Int or Int64 value", span);
			if (!sameType(right.type, TInt))
				fail("E1010", "Shift counts must be Int values", span);
			var shift:TypedExpressionKind = switch operation {
				case 3: TShiftLeft(left, right);
				case 4: TShiftRight(left, right);
				default: TUnsignedShiftRight(left, right);
			};
			return new TypedExpression(shift, left.type, span);
		}

		if ((!sameType(left.type, TInt) && !sameType(left.type, TInt64)) || (!sameType(right.type, TInt) && !sameType(right.type, TInt64)))
			fail("E1010", "Bitwise operators require integer operands", span);
		var operandType = sameType(left.type, TInt64) || sameType(right.type, TInt64) ? TInt64 : TInt;
		left = coerce(left, operandType, "bitwise operand", "E1010");
		right = coerce(right, operandType, "bitwise operand", "E1010");
		var expression:TypedExpressionKind = switch operation {
			case 0: TBitAnd(left, right);
			case 1: TBitXor(left, right);
			case 2: TBitOr(left, right);
			default: throw "Unknown bitwise operation";
		};
		return new TypedExpression(expression, operandType, span);
	}

	public function comparison(a:AstExpression, b:AstExpression, scope:Scope, operation:Int, span:SourceSpan, ?symbol:String,
			reversed:Bool = false):TypedExpression {
		var left = typeExpressionCallback(a, scope, null, false),
			right = EnumAbstractHints.typed(session, EnumAbstractHints.declaredAs(session, left), b, () -> typeExpressionCallback(b, scope, left.type, false));
		if (symbol == null)
			symbol = operation == 0 ? "<" : operation == 1 ? "<=" : "==";
		var overloaded = callResolver.typeAbstractOperator(symbol, [left, right], span, scope);
		if (overloaded != null)
			return overloaded;
		return compareTyped(left, right, operation, span, reversed);
	}

	function compareTyped(left:TypedExpression, right:TypedExpression, operation:Int, span:SourceSpan, reversed:Bool):TypedExpression {
		if (operation != 2 && sameType(left.type, TString) && sameType(right.type, TString)) {
			// Compare content in source operand order; reversing the numeric result
			// must not reverse evaluation of side-effecting string expressions.
			var order = new TypedExpression(TCall("__string_compare_full", [left, right]), TInt, span);
			var zero = new TypedExpression(TIntLiteral(0), TInt, span);
			var first = reversed ? zero : order,
				second = reversed ? order : zero;
			return new TypedExpression(operation == 0 ? TLess(first, second) : TLessEqual(first, second), TBool, span);
		}
		if (reversed) {
			var original = left;
			left = right;
			right = original;
		}
		if (operation == 2
			&& ((sameType(left.type, TNull) && !isNullable(right.type) && right.type != TNull && !TypeRelations.isReference(right.type))
				|| (sameType(right.type, TNull) && !isNullable(left.type) && left.type != TNull && !TypeRelations.isReference(left.type))))
			return new TypedExpression(TBoolLiteral(false), TBool, span);
		if (operation == 2) {
			if (sameType(left.type, TNull) && isNullable(right.type))
				left = coerce(left, right.type, "null comparison", "E1009");
			else if (sameType(right.type, TNull) && isNullable(left.type))
				right = coerce(right, left.type, "null comparison", "E1009");
		}
		if (operation == 2 && sameType(left.type, TString) && sameType(right.type, TString))
			return new TypedExpression(TEqual(left, right), TBool, span);
		if (operation == 2 && sameType(left.type, TBool) && sameType(right.type, TBool))
			return new TypedExpression(TEqual(left, right), TBool, span);
		if (operation == 2 && TypeRelations.equals(left.type, right.type) && session.relations.isValueClass(left.type)) {
			EqualityGenerator.request(session, left.type, session.currentContext.name, span);
			return new TypedExpression(TCall(EqualityGenerator.equalsName(left.type), [left, right]), TBool, span);
		}
		if (operation == 2 && session.relations.isAssignable(left.type, right.type)) {
			left = coerce(left, right.type, "equality comparison", "E1011");
			return new TypedExpression(TEqual(left, right), TBool, span);
		}
		if (operation == 2 && session.relations.isAssignable(right.type, left.type)) {
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
					TNullable(_), TArray(_), TIterator(_), TMap(_, _), TFunction(_, _), TAnonymous(_, _):
					return new TypedExpression(TEqual(left, right), TBool, span);
				default:
			}
		if (operation == 2) {
			var widenedRight = widenToNullableNumeric(right, left.type),
				widenedLeft = widenToNullableNumeric(left, right.type);
			if (widenedRight != null)
				return new TypedExpression(TEqual(left, widenedRight), TBool, span);
			if (widenedLeft != null)
				return new TypedExpression(TEqual(widenedLeft, right), TBool, span);
		}
		var dynamicOrder = dynamicOperation(operation == 0 ? "less" : "lessEqual", [left, right], TBool, span, true);
		if (dynamicOrder != null)
			return dynamicOrder;
		if (!isNumeric(left.type) || !isNumeric(right.type)) {
			fail("E1011", "Comparison requires matching numeric operands", span);
		}
		var promoted = promoteNumericOperands(left, right, span);
		left = promoted.left;
		right = promoted.right;
		return new TypedExpression(switch operation {
			case 0: TLess(left, right);
			case 1: TLessEqual(left, right);
			default: TEqual(left, right);
		}, TBool, span);
	}

	/**
	 * `value` as a value of the nullable numeric type `other`, when it is a plain number that widens to the type
	 * `other` wraps: `Null<Float> == 40` compares as a Float when the value is there, and is false when it is not.
	 * Ordering comparisons of a nullable stay an error, since null has no place in the order.
	 */
	function widenToNullableNumeric(value:TypedExpression, other:CompilerType):Null<TypedExpression> {
		var inner = switch other {
			case TNullable(element): element;
			default: return null;
		};
		// Only widenings that lose nothing: an Int into a Float or an Int64. Int64 and Float stay an explicit conversion.
		if (!sameType(value.type, TInt) || !(sameType(inner, TFloat) || sameType(inner, TInt64)))
			return null;
		return coerce(coerce(value, inner, "numeric operand", "E1010"), other, "equality comparison", "E1011");
	}

	function notEqual(a:AstExpression, b:AstExpression, scope:Scope, span:SourceSpan):TypedExpression {
		var left = typeExpressionCallback(a, scope, null, false),
			right = EnumAbstractHints.typed(session, EnumAbstractHints.declaredAs(session, left), b, () -> typeExpressionCallback(b, scope, left.type, false)),
			overloaded = callResolver.typeAbstractOperator("!=", [left, right], span, scope);
		if (overloaded != null)
			return overloaded;
		return new TypedExpression(TNot(compareTyped(left, right, 2, span, false)), TBool, span);
	}

	public function isNumeric(type:CompilerType):Bool
		return sameType(type, TInt) || sameType(type, TInt64) || sameType(type, TFloat);

	function promoteNumericOperands(left:TypedExpression, right:TypedExpression, span:SourceSpan, forceFloat:Bool = false):{
		left:TypedExpression,
		right:TypedExpression,
		type:CompilerType
	} {
		var hasInt64 = sameType(left.type, TInt64) || sameType(right.type, TInt64);
		var hasFloat = sameType(left.type, TFloat) || sameType(right.type, TFloat);
		if (hasInt64 && hasFloat)
			fail("E1010", "Int64 and Float arithmetic requires an explicit conversion", span);
		var type = hasInt64 ? TInt64 : forceFloat || hasFloat ? TFloat : TInt;
		return {left: coerce(left, type, "numeric operand", "E1010"), right: coerce(right, type, "numeric operand", "E1010"), type: type};
	}

	function isStringConvertible(type:CompilerType):Bool
		return switch type {
			case TString: true;
			case TAbstract(_, _, _): session.relations.isAssignable(type, TString);
			default: false;
		};

	/** A `+` with an operand of this type concatenates: a String, or a nullable one. */
	function isStringOperand(type:CompilerType):Bool
		return switch type {
			case TNullable(inner): isStringConvertible(inner);
			default: isStringConvertible(type);
		};

	function stringify(value:TypedExpression):TypedExpression {
		if (isStringConvertible(value.type))
			return coerce(value, TString, "string concatenation", "E1010");
		// A Null<String> is the same reference as a String, and concatenation itself writes null as "null".
		switch value.type {
			case TNullable(inner) if (sameType(inner, TString)):
				return new TypedExpression(TCast(value), TString, value.span);
			default:
		}
		if (sameType(value.type, TFloat) || sameType(value.type, TDynamic)) {
			session.runtimeDependencyTracker.record(session.currentContext.name, "Std");
			var dynamicValue = coerce(value, TDynamic, "string concatenation", "E1010");
			return new TypedExpression(TCall("Std.string", [dynamicValue]), TString, value.span);
		}
		var dynamicValue = coerce(value, TDynamic, "string concatenation", "E1010");
		return new TypedExpression(TCall("__std_string", [dynamicValue]), TString, value.span);
	}

	static function sameType(left:CompilerType, right:CompilerType):Bool
		return TypeRelations.equals(left, right);

	public static function anonymousFields(type:Null<CompilerType>):Null<Array<AnonymousField>> {
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

	public static function arrayElementExpectation(type:Null<CompilerType>):Null<CompilerType> {
		if (type == null)
			return null;
		return switch type {
			case TArray(element): element;
			case TNullable(element): arrayElementExpectation(element);
			default: null;
		};
	}

	public static function mapExpectation(type:Null<CompilerType>):Null<{key:CompilerType, value:CompilerType}> {
		if (type == null)
			return null;
		return switch type {
			case TMap(key, value): {key: key, value: value};
			case TNullable(element): mapExpectation(element);
			default: null;
		};
	}

	public static function anonymousField(fields:Null<Array<AnonymousField>>, name:String):Null<AnonymousField> {
		if (fields != null)
			for (field in fields)
				if (field.name == name)
					return field;
		return null;
	}

	static function anonymousTypeName(fields:Array<AnonymousField>):String
		return SemanticSignature.anonymousTypeName(fields);

	/** Argument effects were applied while typing them; only the callee itself is checked here. */
	function isPureCallExpression(call:TypedExpression):Bool
		return switch call.expression {
			case TCall(name, _), TCNativeCall(name, _), TMethodCall(_, name, _): session.isPureCall(name);
			case TCast(inner), TAbiCast(inner), TNoReturn(inner): isPureCallExpression(inner);
			default: false;
		};

	static function isNullable(type:CompilerType):Bool
		return switch type {
			case TNullable(_): true;
			default: false;
		};

	static function unwrapNullable(value:TypedExpression):TypedExpression
		return switch value.type {
			case TNullable(element): new TypedExpression(value.expression, element, value.span);
			default: value;
		};

	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));
}
