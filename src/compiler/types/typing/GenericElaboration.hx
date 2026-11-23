package compiler.types.typing;

import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.ParameterConversionKind;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedTypeMap;

/**
 * The elaboration pass of docs/design/GENERIC_TYPING_ONCE.md, stage 2: a body typed with its own type parameters made into the
 * code of one representation of them. Each type parameter is replaced by what the representation substitutes for it, and each
 * conversion the typer recorded where a type parameter meets another type (`TParameterConversion`) is made as typing the body
 * with the substituted types makes it, carrying the conversion it stands for (`TypedExpression.parameterSource`).
 *
 * It runs inside the body's typing context, before the context is left, so what a conversion asks for (a helper, an adapter)
 * is named and recorded as the body's typing would. Its output is the code that typing the body again with the representation's
 * substitutions gives; the test driver checks so (`CompileOptions.elaborateGenerics`).
 */
class GenericElaboration extends TypedTypeMap {
	final owners:Array<String>;
	final substitutions:Map<String, CompilerType>;
	final typer:BodyTyping;

	/**
	 * The elaboration of the type parameters of `owners` (a class, or a function and its owner) as `substitutions` gives them, by
	 * name; `typer` makes each conversion and operation for the substituted types, as typing them does.
	 */
	public function new(owners:Array<String>, substitutions:Map<String, CompilerType>, typer:BodyTyping) {
		this.owners = owners;
		this.substitutions = substitutions;
		this.typer = typer;
		super(type -> substitute(type, owners, substitutions));
	}

	override public function expression(item:TypedExpression):TypedExpression
		return switch item.expression {
			case TParameterConversion(value, kind): conversion(item, expression(value), kind);
			case TParameterOperation(operation, arguments):
				typer.elaborateOperation(switch operation {
					case LayoutQuery(kind, queried, field): LayoutQuery(kind, type(queried), field);
					default: operation;
				}, [for (argument in arguments) expression(argument)], item.span);
			default: super.expression(item);
		};

	function conversion(item:TypedExpression, value:TypedExpression, kind:ParameterConversionKind):TypedExpression {
		var source = switch item.expression {
			case TParameterConversion(original, _): original.type;
			default: item.type;
		};
		var made = switch kind {
			case Coerce: typer.coerce(value, type(item.type), "a generic body's conversion");
			case Boundary: typer.elaborateBoundary(value, type(item.type));
		};
		if (made == value)
			return made;
		return new TypedExpression(made.expression, made.type, made.span, made.stableFlowValue, made.mapKeySource,
			made.storageType, made.semanticReference,
			{source: source, target: item.type, substitutions: substitutions});
	}

	/** `type` with each type parameter of `owners` replaced by its representation in `substitutions`. */
	static function substitute(type:CompilerType, owners:Array<String>,
			substitutions:Map<String, CompilerType>):CompilerType
		return new ParameterSubstitution(owners, substitutions).within(type);
}

/**
 * One substitution of a body's own type parameters (`GenericElaboration`), through every type that can hold them: a structure's
 * fields too (an `Iterator<T>` is `{hasNext, next():T}`), as the typer resolves the structure at the substituted types. A
 * structure is rebuilt only when a field mentions a substituted parameter; one that contains itself is rebuilt once, its fields
 * reaching the rebuilt structure.
 */
private class ParameterSubstitution {
	final owners:Array<String>;
	final substitutions:Map<String, CompilerType>;

	/** The structures being rebuilt, by their fields, with what they are rebuilt as and whether their own fields reached them. */
	final structures:Array<{from:Array<compiler.types.Type.AnonymousField>, to:CompilerType, reentered:Bool}> = [];

	public function new(owners:Array<String>, substitutions:Map<String, CompilerType>) {
		this.owners = owners;
		this.substitutions = substitutions;
	}

	public function within(type:CompilerType):CompilerType {
		function each(types:Array<CompilerType>):Array<CompilerType>
			return [for (part in types) within(part)];
		return switch type {
			case TTypeParameter(owner, name) if (owners.indexOf(owner) >= 0):
				var replacement = substitutions.get(name);
				replacement == null ? type : replacement;
			case TNullable(element): TNullable(within(element));
			case TArray(element): TArray(within(element));
			case TIterator(element): TIterator(within(element));
			case TMap(key, value): TMap(within(key), within(value));
			case TKeyPath(root, value, writable): TKeyPath(within(root), within(value), writable);
			case TFunction(arguments, result, optional): TFunction(each(arguments), within(result), optional);
			case TInstance(kind, name, arguments): TInstance(kind, name, each(arguments));
			case TAbstract(name, arguments, representation): TAbstract(name, each(arguments), within(representation));
			case TAnonymous(name, fields): structure(type, name, fields);
			default: type;
		};
	}

	function structure(type:CompilerType, name:String, fields:Array<compiler.types.Type.AnonymousField>):CompilerType {
		for (entry in structures)
			if (entry.from == fields) {
				entry.reentered = true;
				return entry.to;
			}
		if (!mentions(type, []))
			return type;
		var made:Array<compiler.types.Type.AnonymousField> = [];
		var result = TAnonymous(name, made), entry = {from: fields, to: result, reentered: false};
		structures.push(entry);
		for (field in fields)
			made.push({
				name: field.name,
				type: within(field.type),
				optional: field.optional,
				isFinal: field.isFinal
			});
		structures.remove(entry);
		// A structure named after its fields is named after the substituted ones, as the typer names it at those types; one its own
		// fields reach keeps its name, which they hold.
		return !entry.reentered && StringTools.startsWith(name, "$anon:")
			? TAnonymous(compiler.semantic.SemanticSignature.anonymousTypeName(made), made) : result;
	}

	/** Whether `type` mentions a type parameter this substitution replaces; `visiting` holds the structures it is inside. */
	function mentions(type:CompilerType, visiting:Array<Array<compiler.types.Type.AnonymousField>>):Bool {
		return switch type {
			case TTypeParameter(owner, name): owners.indexOf(owner) >= 0 && substitutions.exists(name);
			case TNullable(element), TArray(element), TIterator(element): mentions(element, visiting);
			case TMap(key, value), TKeyPath(key, value, _): mentions(key, visiting) || mentions(value, visiting);
			case TFunction(arguments, result, _):
				for (argument in arguments)
					if (mentions(argument, visiting))
						return true;
				mentions(result, visiting);
			case TInstance(_, _, arguments):
				for (argument in arguments)
					if (mentions(argument, visiting))
						return true;
				false;
			case TAbstract(_, arguments, representation):
				for (argument in arguments)
					if (mentions(argument, visiting))
						return true;
				mentions(representation, visiting);
			case TAnonymous(_, fields):
				if (visiting.indexOf(fields) >= 0)
					return false;
				visiting.push(fields);
				var found = false;
				for (field in fields)
					if (mentions(field.type, visiting)) {
						found = true;
						break;
					}
				visiting.pop();
				found;
			default: false;
		};
	}
}
