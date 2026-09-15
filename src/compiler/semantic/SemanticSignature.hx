package compiler.semantic;

import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstProgram;
import compiler.syntax.Ast.AstType;
import compiler.syntax.Ast.AstTypeAlias;
import compiler.Source.SourceSpan;
import compiler.types.FieldInference;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;

/** Deterministic spelling for resolved semantic types and callable signatures. */
class SemanticSignature {
	/**
	 * The declaration context that can affect the typing of a recovered body.
	 *
	 * Function bodies are intentionally omitted. This lets the editor typer reuse
	 * an unchanged body when another declaration body changed, while changes to
	 * imports, aliases, nominal shapes, fields, inheritance, or signatures still
	 * invalidate the reuse candidate.
	 */
	public static function recoveryContext(program:AstProgram):String {
		var result:Array<String> = ["package:" + (program.packageName == null ? "" : program.packageName)],
			imports = program.imports.copy();
		imports.sort(Reflect.compare);
		result.push("imports:" + imports.join(","));
		var importAliases:Array<String> = [];
		for (alias => path in program.importAliases)
			importAliases.push(alias + "=" + path);
		importAliases.sort(Reflect.compare);
		result.push("import-aliases:" + importAliases.join(","));

		var aliases = program.aliases.copy();
		aliases.sort(function(left, right) return Reflect.compare(left.name, right.name));
		for (alias in aliases)
			result.push("alias:" + alias.name
				+ (alias.typeParameters.length == 0 ? "" : "<" + parsedParameters(alias.typeParameters, alias.typeConstraints, program.aliases) + ">")
				+ (alias.isPrivate ? ":private" : ":public")
				+ "=" + parsed(alias.type, program.aliases));

		var enums = program.enums.copy();
		enums.sort(function(left, right) return Reflect.compare(left.name, right.name));
		for (decl in enums) {
			var cases = [
				for (caseDecl in decl.cases)
					caseDecl.name + "(" + [
						for (parameter in caseDecl.params)
							(parameter.name == null ? "" : parameter.name + ":")
							+ (parameter.optional ? "?" : "")
							+ parsed(parameter.type, program.aliases)
					].join(",") + ")"
			].join(";");
			result.push("enum:" + decl.name
				+ (decl.typeParameters.length == 0 ? "" : "<" + parsedParameters(decl.typeParameters, decl.typeConstraints, program.aliases) + ">")
				+ "{" + cases + "}");
		}

		var enumAbstracts = program.enumAbstracts.copy();
		enumAbstracts.sort(function(left, right) return Reflect.compare(left.name, right.name));
		for (decl in enumAbstracts) {
			var values = [for (value in decl.values) value.name + "=" + sourceSlice(value.span)].join(";");
			result.push("enum-abstract:" + decl.name
				+ "(" + parsed(decl.underlying, program.aliases) + ")"
				+ " from " + [for (type in decl.fromTypes) parsed(type, program.aliases)].join(",")
				+ " to " + [for (type in decl.toTypes) parsed(type, program.aliases)].join(",")
				+ "{" + values + "}");
		}

		var interfaces = program.interfaces.copy();
		interfaces.sort(function(left, right) return Reflect.compare(left.name, right.name));
		for (decl in interfaces)
			result.push("interface:" + decl.name
				+ (decl.typeParameters.length == 0 ? "" : "<" + parsedParameters(decl.typeParameters, decl.typeConstraints, program.aliases) + ">")
				+ " extends " + [for (base in decl.bases) parsed(base, program.aliases)].join(",")
				+ "{" + [for (method in decl.methods) methodContext(method, program.aliases)].join(";") + "}");

		var classes = program.classes.copy();
		classes.sort(function(left, right) return Reflect.compare(left.name, right.name));
		for (decl in classes) {
			var fields = [for (field in decl.fields) fieldContext(field, program.aliases)].join(";");
			result.push("class:" + decl.name
				+ (decl.isExtern == true ? ":extern" : ":source")
				+ (decl.isPrivate ? ":private" : ":public")
				+ (decl.typeParameters.length == 0 ? "" : "<" + parsedParameters(decl.typeParameters, decl.typeConstraints, program.aliases) + ">")
				+ " base=" + (decl.base == null ? "" : parsed(decl.base, program.aliases))
				+ " interfaces=" + [for (type in decl.interfaces) parsed(type, program.aliases)].join(",")
				+ " metadata=" + metadataContext(decl.metadata)
				+ " fields={" + fields + "}"
				+ " methods={" + [for (method in decl.methods) methodContext(method, program.aliases)].join(";") + "}");
		}

		var abstracts = program.abstracts.copy();
		abstracts.sort(function(left, right) return Reflect.compare(left.name, right.name));
		for (decl in abstracts)
			result.push("abstract:" + decl.name
				+ (decl.isExtern == true ? ":extern" : ":source")
				+ (decl.typeParameters.length == 0 ? "" : "<" + parsedParameters(decl.typeParameters, decl.typeConstraints, program.aliases) + ">")
				+ "(" + parsed(decl.underlying, program.aliases) + ")"
				+ " from=" + [for (type in decl.fromTypes) parsed(type, program.aliases)].join(",")
				+ " to=" + [for (type in decl.toTypes) parsed(type, program.aliases)].join(",")
				+ " metadata=" + metadataContext(decl.metadata)
				+ " methods={" + [for (method in decl.methods) methodContext(method, program.aliases)].join(";") + "}");

		var functions = program.functions.copy();
		functions.sort(function(left, right) return Reflect.compare(left.name, right.name));
		for (fn in functions)
			result.push("function:" + methodContext(fn, program.aliases));
		return result.join("|");
	}

	static function methodContext(fn:AstFunction, aliases:Array<AstTypeAlias>):String
		return fn.name + (fn.isStatic ? ":static" : ":instance") + (fn.isExtern == true ? ":extern" : ":source")
			+ ":" + parsedFunction(fn, aliases);

	static function fieldContext(field:compiler.syntax.Ast.AstField, aliases:Array<AstTypeAlias>):String {
		var fieldType:AstType = try FieldInference.parsedType(field) catch (_:Dynamic) ErrorType(field.span);
		return field.name
			+ (field.isStatic ? ":static" : ":instance")
			+ (field.isInline ? ":inline" : ":normal")
			+ (field.isFinal ? ":final" : ":mutable")
			+ ":" + parsed(fieldType, aliases)
			// Include the complete field declaration so changes to inferred or
			// constant initializer semantics cannot reuse an old body.
			+ ":" + sourceSlice(field.span);
	}

	static function metadataContext(metadata:Array<compiler.syntax.Ast.AstMetadata>):String {
		var result = [for (entry in metadata) sourceSlice(entry.span)];
		result.sort(Reflect.compare);
		return result.join(",");
	}

	static function sourceSlice(span:SourceSpan):String {
		try
			return span.file.slice(span.start, span.end)
		catch (_:Dynamic)
			return "";
	}

	public static function anonymousTypeName(fields:Array<compiler.types.Type.AnonymousField>):String
		return '$' + 'anon:' + anonymousFields(fields);

	static function anonymousFields(fields:Array<compiler.types.Type.AnonymousField>):String {
		var ordered = fields.copy();
		ordered.sort(function(left, right) return Reflect.compare(left.name, right.name));
		return '{${[for (field in ordered) (field.optional ? "?" : "") + field.name + ":" + type(field.type)].join(",")}}';
	}

	public static function type(semanticType:CompilerType):String
		return switch semanticType {
			case TInt: "Int";
			case TInt64: "haxe.Int64";
			case TBool: "Bool";
			case TFloat: "Float";
			case TString: "String";
			case TBytes: "Bytes";
			case THlBytes: "hl.Bytes";
			case TUnknown: "Unknown";
			case TError: "Error";
			case TDynamic: "Dynamic";
			case TNativeAbstract(name): 'hl.Abstract<"$name">';
			case TNativeScalar(name): 'native-scalar:$name';
			case TNever: "Never";
			case TRange: "Range";
			case TVoid: "Void";
			case TTypeParameter(owner, name): 'type-parameter:$owner:$name';
			case TAbstract(name, arguments, _): 'abstract:$name<${[for (argument in arguments) type(argument)].join(",")}>';
			case TInstance(kind, name, arguments):
				var prefix = switch kind {
					case NominalKind.Class: "class";
					case NominalKind.Interface: "interface";
					case NominalKind.Enum: "enum";
					case NominalKind.NativeValue: "native-value";
					default: throw 'Unknown nominal kind $kind';
				};
				'$prefix:$name<${[for (argument in arguments) type(argument)].join(",")}>';
			case TNull: "null";
			case TNullable(element): 'Null<${type(element)}>';
			case TArray(element): 'Array<${type(element)}>';
			case TIterator(element): 'Iterator<${type(element)}>';
			case TMap(key, value): 'Map<${type(key)},${type(value)}>';
			case TFunction(arguments, result): '(${[for (argument in arguments) type(argument)].join(",")})->${type(result)}';
			case TAnonymous(name, _): name;
		};

	public static function parsedFunction(fn:AstFunction, aliases:Array<AstTypeAlias>):String {
		var definitions:Map<String, AstType> = [for (alias in aliases) alias.name => alias.type],
			typeParameters = fn.typeParameters;
		return fn.name
			+ (typeParameters == null
				|| typeParameters.length == 0 ? "" : '<${[for (parameter in typeParameters) parameter + parsedConstraint(fn, parameter, definitions)].join(",")}>')
			+ "("
			+ [for (argument in fn.arguments) parsedType(argument.type, definitions, [])].join(",") + ")->" + parsedType(fn.result, definitions, []);
	}

	static function parsedConstraint(fn:AstFunction, parameter:String, definitions:Map<String, AstType>):String {
		var constraints = fn.typeConstraints;
		if (constraints != null)
			for (constraint in constraints)
				if (constraint.parameter == parameter)
					return ":" + parsedType(constraint.type, definitions, []);
		return "";
	}

	public static function parsed(type:AstType, aliases:Array<AstTypeAlias>):String
		return parsedType(type, [for (alias in aliases) alias.name => alias.type], []);

	public static function parsedParameters(parameters:Array<String>, constraints:Null<Array<compiler.syntax.Ast.AstTypeConstraint>>,
			aliases:Array<AstTypeAlias>):String {
		var definitions:Map<String, AstType> = [for (alias in aliases) alias.name => alias.type];
		return [
			for (parameter in parameters)
				parameter + parsedParameterConstraint(parameter, constraints, definitions)
		].join(",");
	}

	static function parsedParameterConstraint(parameter:String, constraints:Null<Array<compiler.syntax.Ast.AstTypeConstraint>>,
			definitions:Map<String, AstType>):String {
		if (constraints == null)
			return "";
		var bounds = [
			for (constraint in constraints)
				if (constraint.parameter == parameter) parsedType(constraint.type, definitions, [])
		];
		return bounds.length == 0 ? "" : bounds.length == 1 ? ":" + bounds[0] : ":(" + bounds.join(",") + ")";
	}

	static function parsedType(type:AstType, aliases:Map<String, AstType>, resolving:Map<String, Bool>):String
		return switch type {
			case ErrorType(_): "_";
			case IntType: "Int";
			case BoolType: "Bool";
			case FloatType: "Float";
			case StringType: "String";
			case VoidType: "Void";
			case InferredType: "_";
			case NativeAbstractType(declaration, tag): '$declaration<"$tag">';
			case NamedType(name):
				if (!aliases.exists(name) || resolving.exists(name)) name; else {
					var alias = aliases.get(name);
					resolving.set(name, true);
					var result = parsedType(alias, aliases, resolving);
					resolving.remove(name);
					result;
				}
			case AppliedType(name, arguments): '$name<${[for (argument in arguments) parsedType(argument, aliases, resolving)].join(",")}>';
			case ArrayType(element): 'Array<${parsedType(element, aliases, resolving)}>';
			case MapType(key, value): 'Map<${parsedType(key, aliases, resolving)},${parsedType(value, aliases, resolving)}>';
			case NullableType(element): 'Null<${parsedType(element, aliases, resolving)}>';
			case FunctionType(arguments, result):
				'(${[for (argument in arguments) parsedType(argument, aliases, resolving)].join(",")})->${parsedType(result, aliases, resolving)}';
			case AnonymousType(fields):
				var ordered = fields.copy();
				ordered.sort(function(left, right) return Reflect.compare(left.name, right.name));
				'{${[for (field in ordered) (field.optional ? "?" : "") + field.name + ":" + parsedType(field.type, aliases, resolving)].join(",")}}';
		};
}
