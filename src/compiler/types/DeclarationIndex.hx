package compiler.types;

import compiler.Ast;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceSpan;
import compiler.types.Type.CompilerType;

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

abstract DeclarationId(String) to String {
	public inline function new(kind:DeclarationKind, name:String)
		this = '$kind:$name';
}

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
	public final aliases:Map<String, AstType> = [];
	public final enums:Map<String, AstEnum> = [];
	public final enumAbstracts:Map<String, compiler.Ast.AstEnumAbstract> = [];
	public final abstracts:Map<String, compiler.Ast.AstAbstract> = [];
	public final interfaces:Map<String, AstInterface> = [];
	public final classes:Map<String, AstClass> = [];
	public final symbols:Map<String, DeclarationSymbol> = [];

	final aliasSpans:Map<String, SourceSpan> = [];
	final fallbackSpan:SourceSpan;

	public function new(program:AstProgram) {
		fallbackSpan = firstSpan(program);
		for (alias in program.aliases) {
			declareType(alias.name, Alias, alias.span);
			aliases.set(alias.name, alias.type);
			aliasSpans.set(alias.name, alias.span);
		}
		for (decl in program.enums) {
			declareType(decl.name, Enum, decl.span);
			enums.set(decl.name, decl);
		}
		for (decl in program.enumAbstracts) {
			declareType(decl.name, Abstract, decl.span);
			enumAbstracts.set(decl.name, decl);
			for (value in decl.values)
				declare(Member, decl.name + "." + value.name, value.span);
		}
		for (decl in program.abstracts) {
			declareType(decl.name, Abstract, decl.span);
			abstracts.set(decl.name, decl);
			for (method in decl.methods)
				declare(Member, decl.name + "." + method.name, method.span);
		}
		for (decl in program.interfaces) {
			declareType(decl.name, Interface, decl.span);
			interfaces.set(decl.name, decl);
			for (method in decl.methods)
				declare(Member, decl.name + "." + method.name, method.span);
		}
		for (decl in program.classes) {
			declareType(decl.name, Class, decl.span);
			classes.set(decl.name, decl);
			for (field in decl.fields)
				declare(Member, decl.name + "." + field.name, field.span);
			for (method in decl.methods)
				declare(Member, decl.name + "." + method.name, method.span);
		}
		for (fn in program.functions)
			declare(Function, fn.name, fn.span);
		validateCycles();
		validateSignatures(program);
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
			case NamedType("Dynamic"): TDynamic;
			case NamedType("hl.Bytes"): THlBytes;
			case NamedType("haxe.io.Bytes"): TBytes;
			case NamedType("haxe.io.BytesInput"): TNativeAbstract("realtime_bytes_input");
			case NamedType("haxe.io.BytesOutput"): TNativeAbstract("realtime_bytes_output");
			case NamedType(name):
				var substitution = substitutions.get(name),
					alias = aliases.get(name);
				if (substitution != null) substitution; else if (alias != null) {
					if (resolving.exists(name))
						fail('Cyclic type alias involving "$name"', aliasSpans.get(name));
					resolving.set(name, true);
					var resolved = resolveInner(alias, aliasSpans.get(name), resolving, substitutions);
					resolving.remove(name);
					resolved;
				} else if (enumAbstracts.exists(name)) resolveInner(enumAbstracts.get(name).underlying, span, resolving,
					substitutions); else if (abstracts.exists(name)) resolveInner(abstracts.get(name).underlying, span, resolving,
					substitutions); else if (interfaces.exists(name)) TInterface(name); else if (enums.exists(name)) TEnum(name); else if (classes.exists(name)
					|| PlatformAbi.isType(name)) TClass(name); else {
					fail('Unknown type "$name"', span);
					TVoid;
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
				var fields = [
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

	static function nullable(type:CompilerType):CompilerType
		return switch type {
			case TNullable(_): type;
			case TString, TDynamic, TNativeAbstract(_), TClass(_), TInterface(_), TEnum(_), TAnonymous(_, _), TArray(_), TFunction(_), TMap(_, _):
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
			case TClass(name), TInterface(name), TEnum(name): name;
			case TNull: "null";
			case TNullable(element): 'Null<${typeKey(element)}>';
			case TArray(element): 'Array<${typeKey(element)}>';
			case TMap(key, value): 'Map<${typeKey(key)},${typeKey(value)}>';
			case TFunction(arguments, result): '(${[for (argument in arguments) typeKey(argument)].join(",")})->${typeKey(result)}';
			case TAnonymous(name, _): name;
		};

	function validateCycles():Void {
		for (name in aliases.keys())
			resolve(NamedType(name), aliasSpans.get(name));
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
				resolveFunction(method);
		}
		for (decl in program.enumAbstracts) {
			resolve(decl.underlying, decl.span);
			for (type in decl.fromTypes)
				resolve(type, decl.span);
			for (type in decl.toTypes)
				resolve(type, decl.span);
		}
		for (decl in program.enums)
			for (caseDecl in decl.cases)
				for (parameter in caseDecl.params)
					resolve(parameter.type, parameter.span);
		for (decl in program.interfaces)
			for (method in decl.methods)
				resolveFunction(method);
		for (decl in program.classes) {
			for (field in decl.fields)
				resolve(FieldInference.parsedType(field), field.span);
			for (method in decl.methods)
				resolveFunction(method);
		}
		for (fn in program.functions)
			resolveFunction(fn);
	}

	function resolveFunction(fn:AstFunction):Void {
		var substitutions:Map<String, CompilerType> = [];
		if (fn.typeParameters != null)
			for (parameter in fn.typeParameters)
				substitutions.set(parameter, TDynamic);
		for (argument in fn.arguments)
			resolve(argument.type, argument.span, substitutions);
		resolve(fn.result, fn.span, substitutions);
	}

	function visitClass(name:String, visiting:Map<String, Bool>):Void {
		var decl = classes.get(name);
		if (decl == null && PlatformAbi.isType(name))
			return;
		if (decl == null)
			fail('Unknown base class "$name"', fallbackSpan);
		if (visiting.exists(name))
			fail('Cyclic class inheritance involving "$name"', decl.span);
		visiting.set(name, true);
		if (decl.base != null)
			visitClass(decl.base, visiting);
		visiting.remove(name);
	}

	function visitInterface(name:String, visiting:Map<String, Bool>):Void {
		var decl = interfaces.get(name);
		if (decl == null)
			fail('Unknown interface "$name"', fallbackSpan);
		if (visiting.exists(name))
			fail('Cyclic interface inheritance involving "$name"', decl.span);
		visiting.set(name, true);
		for (base in decl.bases)
			visitInterface(base, visiting);
		visiting.remove(name);
	}

	function declareType(name:String, kind:DeclarationKind, span:SourceSpan):Void {
		for (existing in [Alias, Enum, Interface, Class])
			if (symbol(existing, name) != null)
				fail('Duplicate type name "$name"', span);
		declare(kind, name, span);
	}

	function declare(kind:DeclarationKind, name:String, span:SourceSpan):Void {
		var key = '$kind:$name';
		if (symbols.exists(key))
			fail('Duplicate declaration "$name"', span);
		symbols.set(key, {
			id: new DeclarationId(kind, name),
			kind: kind,
			name: name,
			span: span
		});
	}

	static function firstSpan(program:AstProgram):SourceSpan {
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
		throw "Cannot index an empty program";
	}

	static function fail(message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic("E1020", message, span));
}
