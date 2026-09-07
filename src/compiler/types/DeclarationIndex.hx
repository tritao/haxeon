package compiler.types;

import compiler.runtime.PlatformAbi;
import compiler.syntax.Ast;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceSpan;
import compiler.Source.SourceFile;
import compiler.semantic.ModuleCanonicalizer;
import compiler.types.Type.AnonymousField;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;

/** Stable category used to identify a source declaration semantically. */
enum abstract DeclarationKind(String) {
	var Alias = "alias";
	var Enum = "enum";
	var Abstract = "abstract";
	var Interface = "interface";
	var Class = "class";
	var Function = "function";
	var Member = "member";
	var EnumCase = "enum-case";
	var TypeParameter = "type-parameter";
}

/** Stable qualified identity assigned independently of declaration objects. */
abstract DeclarationId(String) from String to String {}

/** Indexed declaration identity, category, source name, and location. */
typedef DeclarationSymbol = {
	final id:DeclarationId;
	final kind:DeclarationKind;
	final name:String;
	final span:SourceSpan;
}

/** Reserved semantic representation; parser support for generics is intentionally deferred. */
typedef TypeParameterSymbol = {
	final id:DeclarationId;
	final name:String;
	final owner:DeclarationId;
	final span:SourceSpan;
}

/** Shared owner of source declarations and parsed-type resolution. */
class DeclarationIndex {
	public final aliases:Map<String, AstTypeAlias> = [];
	public final enums:Map<String, AstEnum> = [];
	public final enumAbstracts:Map<String, compiler.syntax.Ast.AstEnumAbstract> = [];
	public final abstracts:Map<String, compiler.syntax.Ast.AstAbstract> = [];
	public final interfaces:Map<String, AstInterface> = [];
	public final classes:Map<String, AstClass> = [];
	public final symbols:Map<String, DeclarationSymbol> = [];
	public final inheritance:NominalInheritance;
	public final conversions:AbstractConversionGraph;

	final aliasSpans:Map<String, SourceSpan> = [];
	final fallbackSpan:SourceSpan;

	public static function validated(program:AstProgram):DeclarationIndex
		return registered(program).validate(program);

	public static function registered(program:AstProgram):DeclarationIndex
		return new DeclarationIndex(program, false, null);

	public static function forModule(program:AstProgram, source:SourceFile):DeclarationIndex
		return new DeclarationIndex(program, false, source.span(0, 0));

	function new(program:AstProgram, validate:Bool, emptySpan:Null<SourceSpan>) {
		fallbackSpan = firstSpan(program, emptySpan);
		for (alias in program.aliases) {
			declareType(alias.name, DeclarationKind.Alias, alias.span);
			aliases.set(alias.name, alias);
			aliasSpans.set(alias.name, alias.span);
		}
		for (decl in program.enums) {
			declareType(decl.name, DeclarationKind.Enum, decl.span);
			enums.set(decl.name, decl);
			for (enumCase in decl.cases)
				declare(DeclarationKind.EnumCase, decl.name + "." + enumCase.name, enumCase.span);
		}
		for (decl in program.enumAbstracts) {
			declareType(decl.name, DeclarationKind.Abstract, decl.span);
			enumAbstracts.set(decl.name, decl);
			for (value in decl.values)
				declare(DeclarationKind.Member, decl.name + "." + value.name, value.span);
		}
		for (decl in program.abstracts) {
			declareType(decl.name, DeclarationKind.Abstract, decl.span);
			abstracts.set(decl.name, decl);
			for (method in decl.methods)
				declare(DeclarationKind.Member, decl.name + "." + method.name, method.span);
		}
		for (decl in program.interfaces) {
			declareType(decl.name, DeclarationKind.Interface, decl.span);
			interfaces.set(decl.name, decl);
			for (method in decl.methods)
				declare(DeclarationKind.Member, decl.name + "." + method.name, method.span);
		}
		for (decl in program.classes) {
			declareType(decl.name, DeclarationKind.Class, decl.span);
			classes.set(decl.name, decl);
			for (field in decl.fields)
				declare(DeclarationKind.Member, decl.name + "." + field.name, field.span);
			for (method in decl.methods)
				declare(DeclarationKind.Member, decl.name + "." + method.name, method.span);
		}
		for (fn in program.functions)
			declare(DeclarationKind.Function, fn.name, fn.span);
		inheritance = new NominalInheritance(this);
		conversions = new AbstractConversionGraph(this, false);
		if (validate) {
			connectShapes();
			validateProgramSignatures(program);
		}
	}

	public function connectShapes():Void
		validateCycles();

	public function validateProgramSignatures(program:AstProgram):Void {
		validateSignatures(program);
		conversions.validate();
	}

	function validate(program:AstProgram):DeclarationIndex {
		connectShapes();
		validateProgramSignatures(program);
		return this;
	}

	public function resolve(type:AstType, ?span:SourceSpan, ?substitutions:Map<String, CompilerType>):CompilerType
		return resolveInner(type, span == null ? fallbackSpan : span, [], substitutions == null ? [] : substitutions);

	public function resolvedFieldType(owner:String, field:compiler.syntax.Ast.AstField):AstType
		return FieldInference.resolvedType(field, owner, classes, []);

	public function symbol(kind:DeclarationKind, name:String):Null<DeclarationSymbol>
		return symbols.get('$kind:$name');

	function resolveInner(type:AstType, span:SourceSpan, resolving:Map<String, Bool>, substitutions:Map<String, CompilerType>):CompilerType
		return switch type {
			case ErrorType(_): TDynamic;
			case IntType: TInt;
			case BoolType: TBool;
			case FloatType: TFloat;
			case StringType: TString;
			case VoidType: TVoid;
			case InferredType:
				fail("Unresolved inferred type", span);
				TDynamic;
			case NativeAbstractType(declaration, tag):
				if (!PlatformAbi.acceptsNativeTag(declaration)
					&& (!abstracts.exists(declaration) || abstractRepresentation(abstracts.get(declaration)) != "nativeAbstract"))
					fail('Type "$declaration" does not accept a native ABI tag', span);
				TNativeAbstract(tag);
			case NamedType(name):
				switch name {
					case "Dynamic", "Any": TDynamic;
					case "haxe.io.Bytes": TBytes;
					default: resolveNamedType(name, span, resolving, substitutions);
				}
			case AppliedType(name, arguments):
				if (name == "List") {
					if (arguments.length != 1)
						fail('Type "List" expects 1 type argument, got ${arguments.length}', span);
					TArray(resolveInner(arguments[0], span, resolving, substitutions));
				} else if (aliases.exists(name)) {
					var alias = aliases.get(name);
					if (arguments.length != alias.typeParameters.length)
						fail('Type "$name" expects ${alias.typeParameters.length} type arguments, got ${arguments.length}', span);
					var resolvedArguments = [
						for (argument in arguments)
							resolveInner(argument, span, resolving, substitutions)
					];
					var aliasSubstitutions = [for (parameter => value in substitutions) parameter => value];
					for (i in 0...alias.typeParameters.length)
						aliasSubstitutions.set(alias.typeParameters[i], resolvedArguments[i]);
					validateTypeArguments(name, alias.typeConstraints, aliasSubstitutions, span);
					resolveAlias(alias, resolving, aliasSubstitutions);
				} else if (abstracts.exists(name)) {
					var decl = abstracts.get(name);
					if (arguments.length != decl.typeParameters.length)
						fail('Type "$name" expects ${decl.typeParameters.length} type arguments, got ${arguments.length}', span);
					var abstractSubstitutions = [for (parameter => value in substitutions) parameter => value];
					for (index in 0...arguments.length)
						abstractSubstitutions.set(decl.typeParameters[index], resolveInner(arguments[index], span, resolving, substitutions));
					var resolvedArguments = [
						for (argument in arguments)
							resolveInner(argument, span, resolving, substitutions)
					];
					validateTypeArguments(name, decl.typeConstraints, abstractSubstitutions, span);
					TAbstract(name, resolvedArguments, resolveAbstract(decl, span, resolving, abstractSubstitutions));
				} else if (classes.exists(name) || interfaces.exists(name) || enums.exists(name)) {
					var declaration:{typeParameters:Array<String>, typeConstraints:Null<Array<compiler.syntax.Ast.AstTypeConstraint>>, kind:NominalKind};
					if (classes.exists(name)) {
						var found = classes.get(name);
						declaration = {typeParameters: found.typeParameters, typeConstraints: found.typeConstraints, kind: NominalKind.Class};
					} else if (interfaces.exists(name)) {
						var found = interfaces.get(name);
						declaration = {typeParameters: found.typeParameters, typeConstraints: found.typeConstraints, kind: NominalKind.Interface};
					} else {
						if (!enums.exists(name))
							throw 'Missing nominal declaration "$name"';
						var found = enums.get(name);
						declaration = {typeParameters: found.typeParameters, typeConstraints: found.typeConstraints, kind: NominalKind.Enum};
					}
					var parameters = declaration.typeParameters,
						constraints = declaration.typeConstraints;
					if (arguments.length != parameters.length)
						fail('Type "$name" expects ${parameters.length} type arguments, got ${arguments.length}', span);
					var resolvedArguments = [
						for (argument in arguments)
							resolveInner(argument, span, resolving, substitutions)
					];
					var applied = declarationSubstitutions(name, parameters);
					for (index in 0...parameters.length)
						applied.set(parameters[index], resolvedArguments[index]);
					validateTypeArguments(name, constraints, applied, span);
					TInstance(declaration.kind, name, resolvedArguments);
				} else {
					fail('Type "$name" does not accept type arguments', span);
					TDynamic;
				}
			case ArrayType(element): TArray(resolveInner(element, span, resolving, substitutions));
			case MapType(key, value): TMap(resolveInner(key, span, resolving, substitutions), resolveInner(value, span, resolving, substitutions));
			case NullableType(element): TNullable(resolveInner(element, span, resolving, substitutions));
			case FunctionType(arguments, result):
				TFunction([
					for (argument in arguments)
						resolveInner(argument, span, resolving, substitutions)
				], resolveInner(result, span, resolving, substitutions));
			case AnonymousType(parsedFields):
				var fields:Array<AnonymousField> = [
					for (field in parsedFields)
						{
							name: field.name,
							type: field.optional ? nullable(resolveInner(field.type, field.span, resolving,
								substitutions)) : resolveInner(field.type, field.span, resolving, substitutions),
							optional: field.optional
						}
				];
				fields.sort(function(left, right) return Reflect.compare(left.name, right.name));
				for (i in 1...fields.length)
					if (fields[i - 1].name == fields[i].name)
						fail('Duplicate anonymous field "${fields[i].name}"', span);
				TAnonymous(compiler.semantic.SemanticSignature.anonymousTypeName(fields), fields);
		};

	function validateTypeArguments(name:String, constraints:Null<Array<compiler.syntax.Ast.AstTypeConstraint>>, substitutions:Map<String, CompilerType>,
			span:SourceSpan):Void {
		if (constraints == null)
			return;
		var relations = new TypeRelations(this);
		for (constraint in constraints) {
			var actual = substitutions.get(constraint.parameter),
				expected = resolve(constraint.type, constraint.span, substitutions);
			if (actual != null)
				switch actual {
					case TTypeParameter(_, _):
						continue;
					default:
				}
			if (actual == null || !relations.isAssignable(actual, expected))
				fail('Type argument for "${constraint.parameter}" on "$name" does not satisfy constraint "${compiler.semantic.SemanticSignature.type(expected)}"',
					span);
		}
	}

	function resolveNamedType(name:String, span:SourceSpan, resolving:Map<String, Bool>, substitutions:Map<String, CompilerType>):CompilerType {
		return if (substitutions.exists(name)) substitutions.get(name); else if (aliases.exists(name)) {
			var alias = aliases.get(name);
			if (alias.typeParameters.length != 0)
				fail('Type "$name" expects ${alias.typeParameters.length} type arguments, got 0', span);
			resolveAlias(alias, resolving, substitutions);
		} else if (enumAbstracts.exists(name)) resolveInner(enumAbstracts.get(name).underlying, span, resolving,
			substitutions); else if (abstracts.exists(name)) {
			var decl = abstracts.get(name);
			if (decl.typeParameters.length != 0)
				fail('Type "$name" expects ${decl.typeParameters.length} type arguments, got 0', span);
			TAbstract(name, [], resolveAbstract(decl, span, resolving, substitutions));
		} else if (interfaces.exists(name)) resolveBareNominal(name, NominalKind.Interface, interfaces.get(name).typeParameters.length,
			span); else if (enums.exists(name)) resolveBareNominal(name, NominalKind.Enum, enums.get(name).typeParameters.length,
			span); else if (classes.exists(name)) resolveBareNominal(name, NominalKind.Class, classes.get(name).typeParameters.length,
			span); else if (PlatformAbi.isType(name)) PlatformAbi.valueType(name); else {
			fail('Unknown type "$name"', span);
			TVoid;
		};
	}

	function resolveBareNominal(name:String, kind:compiler.types.Type.NominalKind, arity:Int, span:SourceSpan):CompilerType {
		if (arity != 0)
			fail('Type "$name" expects $arity type arguments, got 0', span);
		return TInstance(kind, name, []);
	}

	function resolveAlias(alias:AstTypeAlias, resolving:Map<String, Bool>, substitutions:Map<String, CompilerType>):CompilerType {
		if (resolving.exists(alias.name))
			fail('Cyclic type alias involving "${alias.name}"', alias.span);
		resolving.set(alias.name, true);
		var resolved = resolveInner(alias.type, alias.span, resolving, substitutions);
		resolving.remove(alias.name);
		return resolved;
	}

	function resolveAbstract(decl:compiler.syntax.Ast.AstAbstract, span:SourceSpan, resolving:Map<String, Bool>,
			substitutions:Map<String, CompilerType>):CompilerType {
		var metadata = decl.metadata;
		if (metadata != null)
			for (entry in metadata)
				if (entry.name == "hlType") {
					if (entry.arguments.length != 1)
						fail('@:hlType requires one representation string', entry.span);
					return switch entry.arguments[0] {
						case StringLiteral("bytes", _): THlBytes;
						case StringLiteral("dynamic", _): TDynamic;
						case StringLiteral(value, _):
							fail('Unknown HashLink representation "$value"', entry.span);
							TDynamic;
						default:
							fail('@:hlType argument must be a string literal', entry.span);
							TDynamic;
					};
				}
		if (resolving.exists(decl.name))
			fail('Cyclic abstract representation involving "${decl.name}"', span);
		resolving.set(decl.name, true);
		var resolved = resolveInner(decl.underlying, span, resolving, substitutions);
		resolving.remove(decl.name);
		return resolved;
	}

	static function abstractRepresentation(decl:compiler.syntax.Ast.AstAbstract):Null<String> {
		var metadata = decl.metadata;
		if (metadata != null)
			for (entry in metadata)
				if (entry.name == "hlType" && entry.arguments.length == 1)
					return switch entry.arguments[0] {
						case StringLiteral(value, _): value;
						default: null;
					};
		return null;
	}

	static function nullable(type:CompilerType):CompilerType
		return switch type {
			case TNullable(_): type;
			case TString, TDynamic, TNativeAbstract(_), TInstance(_, _, _), TAnonymous(_, _), TArray(_), TFunction(_, _), TMap(_, _):
				TNullable(type);
			default: type;
		};

	static function typeKey(type:CompilerType):String
		return switch type {
			case TInt: "Int";
			case TBool: "Bool";
			case TFloat: "Float";
			case TString: "String";
			case TBytes: "Bytes";
			case THlBytes: "hl.Bytes";
			case TDynamic: "Dynamic";
			case TNativeAbstract(name): 'hl.Abstract<$name>';
			case TNever: "Never";
			case TRange: "Range";
			case TVoid: "Void";
			case TTypeParameter(owner, name): 'type-parameter:$owner:$name';
			case TAbstract(name, arguments, _): arguments.length == 0 ? name : '$name<${[for (argument in arguments) typeKey(argument)].join(",")}>';
			case TInstance(_, name, arguments): arguments.length == 0 ? name : '$name<${[for (argument in arguments) typeKey(argument)].join(",")}>';
			case TNull: "null";
			case TNullable(element): 'Null<${typeKey(element)}>';
			case TArray(element): 'Array<${typeKey(element)}>';
			case TMap(key, value): 'Map<${typeKey(key)},${typeKey(value)}>';
			case TFunction(arguments, result): '(${[for (argument in arguments) typeKey(argument)].join(",")})->${typeKey(result)}';
			case TAnonymous(name, _): name;
		};

	function validateCycles():Void {
		for (name in aliases.keys()) {
			if (!aliases.exists(name))
				throw 'Alias "$name" disappeared during cycle validation';
			var alias = aliases.get(name),
				substitutions:Map<String, CompilerType> = [];
			for (parameter in alias.typeParameters)
				substitutions.set(parameter, TTypeParameter(alias.name, parameter));
			resolveAlias(alias, [], substitutions);
		}
		for (name in classes.keys()) {
			visitClass(name, []);
			if (!classes.exists(name))
				throw 'Class "$name" disappeared during cycle validation';
			var decl = classes.get(name);
			for (interfaceType in decl.interfaces) {
				var interfaceName = nominalName(resolve(interfaceType, decl.span));
				if (interfaceName == null || !interfaces.exists(interfaceName))
					fail('Unknown interface "${ModuleCanonicalizer.astTypeName(interfaceType)}"', decl.span);
			}
		}
		for (name in interfaces.keys())
			visitInterface(name, []);
		validateInterfaceInstantiations();
	}

	function validateInterfaceInstantiations():Void {
		for (name in interfaces.keys()) {
			if (!interfaces.exists(name))
				throw 'Interface "$name" disappeared during inheritance validation';
			var decl = interfaces.get(name);
			validateInterfaceSet(inheritance.inheritedInterfaces(TInstance(NominalKind.Interface, decl.name, [
				for (parameter in decl.typeParameters)
					TTypeParameter(decl.name, parameter)
			])), decl.span);
		}
		for (name in classes.keys()) {
			if (!classes.exists(name))
				throw 'Class "$name" disappeared during inheritance validation';
			var decl = classes.get(name);
			validateInterfaceSet(inheritance.inheritedInterfaces(TInstance(NominalKind.Class, decl.name, [
				for (parameter in decl.typeParameters)
					TTypeParameter(decl.name, parameter)
			])), decl.span);
		}
	}

	function validateInterfaceSet(instances:Array<CompilerType>, span:SourceSpan):Void {
		var inherited:Map<String, CompilerType> = [];
		for (instance in instances) {
			var name = requiredNominalName(instance);
			if (inherited.exists(name)) {
				var previous = inherited.get(name);
				if (!TypeRelations.equals(previous, instance))
					fail('Conflicting inherited interface instantiations for "$name": ${typeKey(previous)} and ${typeKey(instance)}', span);
			}
			inherited.set(name, instance);
		}
	}

	function validateSignatures(program:AstProgram):Void {
		for (decl in program.abstracts) {
			var substitutions = declarationSubstitutions(decl.name, decl.typeParameters);
			resolve(decl.underlying, decl.span, substitutions);
			var fromKeys:Map<String, Bool> = [], toKeys:Map<String, Bool> = [];
			for (type in decl.fromTypes)
				validateAbstractConversion(decl.name, "from", resolve(type, decl.span, substitutions), fromKeys, decl.span);
			for (type in decl.toTypes)
				validateAbstractConversion(decl.name, "to", resolve(type, decl.span, substitutions), toKeys, decl.span);
			for (method in decl.methods)
				resolveFunction(method, decl.name, substitutions);
		}
		for (decl in program.enumAbstracts) {
			resolve(decl.underlying, decl.span);
			for (type in decl.fromTypes)
				resolve(type, decl.span);
			for (type in decl.toTypes)
				resolve(type, decl.span);
		}
		for (decl in program.enums) {
			var substitutions:Map<String, CompilerType> = [];
			for (parameter in decl.typeParameters)
				substitutions.set(parameter, TTypeParameter(decl.name, parameter));
			for (caseDecl in decl.cases)
				for (parameter in caseDecl.params)
					resolve(parameter.type, parameter.span, substitutions);
		}
		for (decl in program.interfaces) {
			var substitutions:Map<String, CompilerType> = [];
			for (parameter in decl.typeParameters)
				substitutions.set(parameter, TTypeParameter(decl.name, parameter));
			for (method in decl.methods)
				resolveFunction(method, decl.name + "." + method.name, substitutions);
		}
		for (decl in program.classes) {
			var substitutions:Map<String, CompilerType> = [];
			for (parameter in decl.typeParameters)
				substitutions.set(parameter, TTypeParameter(decl.name, parameter));
			for (field in decl.fields)
				resolve(resolvedFieldType(decl.name, field), field.span, substitutions);
			for (method in decl.methods)
				resolveFunction(method, decl.name + "." + method.name, substitutions);
		}
		for (fn in program.functions)
			resolveFunction(fn, fn.name);
	}

	function validateAbstractConversion(name:String, direction:String, type:CompilerType, seen:Map<String, Bool>, span:SourceSpan):Void {
		var key = typeKey(type);
		if (seen.exists(key))
			fail('Duplicate $direction conversion "$key" on abstract "$name"', span);
		seen.set(key, true);
	}

	function resolveFunction(fn:AstFunction, owner:String, ?ownerSubstitutions:Map<String, CompilerType>):Void {
		var substitutions:Map<String, CompilerType> = ownerSubstitutions == null ? [] : [for (name => type in ownerSubstitutions) name => type],
			typeParameters = fn.typeParameters;
		if (typeParameters != null)
			for (parameter in typeParameters)
				substitutions.set(parameter, TTypeParameter(owner, parameter));
		var constraints = fn.typeConstraints;
		if (constraints != null)
			for (constraint in constraints)
				resolve(constraint.type, constraint.span, substitutions);
		for (argument in fn.arguments)
			resolve(argument.type, argument.span, substitutions);
		resolve(fn.result, fn.span, substitutions);
	}

	function visitClass(name:String, visiting:Map<String, Bool>):Void {
		if (!classes.exists(name)) {
			if (PlatformAbi.isType(name))
				return;
			fail('Unknown base class "$name"', fallbackSpan);
		}
		var decl = classes.get(name);
		if (visiting.exists(name))
			fail('Cyclic class inheritance involving "$name"', decl.span);
		visiting.set(name, true);
		var base = decl.base;
		if (base != null) {
			var substitutions = declarationSubstitutions(decl.name, decl.typeParameters);
			visitClass(requiredNominalName(resolve(base, decl.span, substitutions)), visiting);
		}
		visiting.remove(name);
	}

	function visitInterface(name:String, visiting:Map<String, Bool>):Void {
		if (!interfaces.exists(name))
			fail('Unknown interface "$name"', fallbackSpan);
		var decl = interfaces.get(name);
		if (visiting.exists(name))
			fail('Cyclic interface inheritance involving "$name"', decl.span);
		visiting.set(name, true);
		var substitutions = declarationSubstitutions(decl.name, decl.typeParameters);
		for (base in decl.bases)
			visitInterface(requiredNominalName(resolve(base, decl.span, substitutions)), visiting);
		visiting.remove(name);
	}

	static function declarationSubstitutions(owner:String, parameters:Array<String>):Map<String, CompilerType> {
		var result:Map<String, CompilerType> = [];
		for (parameter in parameters)
			result.set(parameter, TTypeParameter(owner, parameter));
		return result;
	}

	static function nominalName(type:CompilerType):Null<String>
		return switch type {
			case TInstance(_, name, _): name;
			default: null;
		};

	static function requiredNominalName(type:CompilerType):String {
		var name = nominalName(type);
		if (name == null)
			throw "Expected nominal inheritance type";
		return name;
	}

	function declareType(name:String, kind:DeclarationKind, span:SourceSpan):Void {
		var typeKinds:Array<DeclarationKind> = [
			DeclarationKind.Alias,
			DeclarationKind.Enum,
			DeclarationKind.Abstract,
			DeclarationKind.Interface,
			DeclarationKind.Class
		];
		for (existing in typeKinds)
			if (symbols.exists('$existing:$name'))
				fail('Duplicate type name "$name"', span);
		declare(kind, name, span);
	}

	function declare(kind:DeclarationKind, name:String, span:SourceSpan):Void {
		var key = '$kind:$name';
		if (symbols.exists(key))
			fail('Duplicate declaration "$name"', span);
		symbols.set(key, {
			id: '$kind:$name',
			kind: kind,
			name: name,
			span: span
		});
	}

	static function firstSpan(program:AstProgram, emptySpan:Null<SourceSpan>):SourceSpan {
		if (program.aliases.length > 0)
			return program.aliases[0].span;
		if (program.enums.length > 0)
			return program.enums[0].span;
		if (program.enumAbstracts.length > 0)
			return program.enumAbstracts[0].span;
		if (program.abstracts.length > 0)
			return program.abstracts[0].span;
		if (program.interfaces.length > 0)
			return program.interfaces[0].span;
		if (program.classes.length > 0)
			return program.classes[0].span;
		if (program.functions.length > 0)
			return program.functions[0].span;
		if (emptySpan == null)
			throw "Cannot index an empty program";
		return emptySpan;
	}

	static function fail(message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic("E1020", message, span));
}
