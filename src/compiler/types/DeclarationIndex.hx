package compiler.types;

import compiler.Ast;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceSpan;
import compiler.Source.SourceFile;
import compiler.types.Type.AnonymousField;
import compiler.types.Type.CompilerType;

/** Stable category used to identify a source declaration semantically. */
enum abstract DeclarationKind(String) {
	var Alias = "alias";
	var Enum = "enum";
	var Abstract = "abstract";
	var Interface = "interface";
	var Class = "class";
	var Function = "function";
	var Member = "member";
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
	public final enumAbstracts:Map<String, compiler.Ast.AstEnumAbstract> = [];
	public final abstracts:Map<String, compiler.Ast.AstAbstract> = [];
	public final interfaces:Map<String, AstInterface> = [];
	public final classes:Map<String, AstClass> = [];
	public final symbols:Map<String, DeclarationSymbol> = [];

	final aliasSpans:Map<String, SourceSpan> = [];
	final fallbackSpan:SourceSpan;

	public static function validated(program:AstProgram):DeclarationIndex
		return new DeclarationIndex(program, true, null);

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
		if (validate) {
			validateCycles();
			validateSignatures(program);
		}
	}

	public function resolve(type:AstType, ?span:SourceSpan, ?substitutions:Map<String, CompilerType>):CompilerType
		return resolveInner(type, span == null ? fallbackSpan : span, [], substitutions == null ? [] : substitutions);

	public function symbol(kind:DeclarationKind, name:String):Null<DeclarationSymbol>
		return symbols.get('$kind:$name');

	function resolveInner(type:AstType, span:SourceSpan, resolving:Map<String, Bool>, substitutions:Map<String, CompilerType>):CompilerType
		return switch type {
			case IntType: TInt;
			case BoolType: TBool;
			case FloatType: TFloat;
			case StringType: TString;
			case VoidType: TVoid;
			case InferredType:
				fail("Unresolved inferred type", span);
				TDynamic;
			case NativeAbstractType(name): TNativeAbstract(name);
			case NamedType(name):
				switch name {
					case "Dynamic": TDynamic;
					case "hl.Bytes": THlBytes;
					case "haxe.io.Bytes": TBytes;
					case "haxe.io.BytesInput": TNativeAbstract("realtime_bytes_input");
					case "haxe.io.BytesOutput": TNativeAbstract("realtime_bytes_output");
					case "Date": TNativeAbstract("realtime_date");
					default: resolveNamedType(name, span, resolving, substitutions);
				}
			case AppliedType(name, arguments):
				if (aliases.exists(name)) {
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
					resolveAlias(alias, resolving, aliasSubstitutions);
				} else if (!enums.exists(name)) {
					fail('Type "$name" does not accept type arguments', span);
					TDynamic;
				} else {
					var declaration = enums.get(name);
					if (arguments.length != declaration.typeParameters.length)
						fail('Type "$name" expects ${declaration.typeParameters.length} type arguments, got ${arguments.length}', span);
					TInstance(Enum, name, [
						for (argument in arguments)
							resolveInner(argument, span, resolving, substitutions)
					]);
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
				var signature = [
					for (field in fields)
						(field.optional ? "?" : "") + field.name + ":" + typeKey(field.type)
				].join(",");
				TAnonymous('$' + 'anon:{$signature}', fields);
		};

	function resolveNamedType(name:String, span:SourceSpan, resolving:Map<String, Bool>, substitutions:Map<String, CompilerType>):CompilerType {
		return if (substitutions.exists(name)) substitutions.get(name); else if (aliases.exists(name)) {
			var alias = aliases.get(name);
			if (alias.typeParameters.length != 0)
				fail('Type "$name" expects ${alias.typeParameters.length} type arguments, got 0', span);
			resolveAlias(alias, resolving, substitutions);
		} else if (enumAbstracts.exists(name)) resolveInner(enumAbstracts.get(name).underlying, span, resolving,
			substitutions); else if (abstracts.exists(name)) resolveInner(abstracts.get(name).underlying, span, resolving,
			substitutions); else if (interfaces.exists(name)) TInstance(Interface, name,
			[]); else if (enums.exists(name)) TInstance(Enum, name,
			[]); else if (classes.exists(name)) TInstance(Class, name, []); else if (PlatformAbi.isType(name)) PlatformAbi.valueType(name); else {
			fail('Unknown type "$name"', span);
			TVoid;
		};
	}

	function resolveAlias(alias:AstTypeAlias, resolving:Map<String, Bool>, substitutions:Map<String, CompilerType>):CompilerType {
		if (resolving.exists(alias.name))
			fail('Cyclic type alias involving "${alias.name}"', alias.span);
		resolving.set(alias.name, true);
		var resolved = resolveInner(alias.type, alias.span, resolving, substitutions);
		resolving.remove(alias.name);
		return resolved;
	}

	static function nullable(type:CompilerType):CompilerType
		return switch type {
			case TNullable(_): type;
			case TString, TDynamic, TNativeAbstract(_), TInstance(Class, _, []), TInstance(Interface, _, []), TInstance(Enum, _, _), TAnonymous(_, _),
				TArray(_), TFunction(_, _), TMap(_, _):
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
			case TInstance(Class, name, arguments), TInstance(Interface, name, arguments):
				arguments.length == 0 ? name : '$name<${[for (argument in arguments) typeKey(argument)].join(",")}>';
			case TInstance(Enum, name, arguments): arguments.length == 0 ? name : '$name<${[for (argument in arguments) typeKey(argument)].join(",")}>';
			case TNull: "null";
			case TNullable(element): 'Null<${typeKey(element)}>';
			case TArray(element): 'Array<${typeKey(element)}>';
			case TMap(key, value): 'Map<${typeKey(key)},${typeKey(value)}>';
			case TFunction(arguments, result): '(${[for (argument in arguments) typeKey(argument)].join(",")})->${typeKey(result)}';
			case TAnonymous(name, _): name;
		};

	function validateCycles():Void {
		for (name in aliases.keys()) {
			var alias = aliases.get(name),
				substitutions:Map<String, CompilerType> = [];
			for (parameter in alias.typeParameters)
				substitutions.set(parameter, TTypeParameter(alias.name, parameter));
			resolveAlias(alias, [], substitutions);
		}
		for (name in classes.keys()) {
			visitClass(name, []);
			var decl = classes.get(name);
			for (interfaceName in decl.interfaces)
				if (!interfaces.exists(interfaceName))
					fail('Unknown interface "$interfaceName"', decl.span);
		}
		for (name in interfaces.keys())
			visitInterface(name, []);
	}

	function validateSignatures(program:AstProgram):Void {
		for (decl in program.abstracts) {
			resolve(decl.underlying, decl.span);
			for (type in decl.fromTypes)
				resolve(type, decl.span);
			for (type in decl.toTypes)
				resolve(type, decl.span);
			for (method in decl.methods)
				resolveFunction(method, decl.name);
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
		for (decl in program.interfaces)
			for (method in decl.methods)
				resolveFunction(method, decl.name + "." + method.name);
		for (decl in program.classes) {
			for (field in decl.fields)
				resolve(FieldInference.parsedType(field), field.span);
			for (method in decl.methods)
				resolveFunction(method, decl.name + "." + method.name);
		}
		for (fn in program.functions)
			resolveFunction(fn, fn.name);
	}

	function resolveFunction(fn:AstFunction, owner:String):Void {
		var substitutions:Map<String, CompilerType> = [],
			typeParameters = fn.typeParameters;
		if (typeParameters != null)
			for (parameter in typeParameters)
				substitutions.set(parameter, TTypeParameter(owner, parameter));
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
		if (base != null)
			visitClass(base, visiting);
		visiting.remove(name);
	}

	function visitInterface(name:String, visiting:Map<String, Bool>):Void {
		if (!interfaces.exists(name))
			fail('Unknown interface "$name"', fallbackSpan);
		var decl = interfaces.get(name);
		if (visiting.exists(name))
			fail('Cyclic interface inheritance involving "$name"', decl.span);
		visiting.set(name, true);
		for (base in decl.bases)
			visitInterface(base, visiting);
		visiting.remove(name);
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
