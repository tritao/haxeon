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
			substitutions:Map<String, CompilerType>):CompilerType {
		function each(types:Array<CompilerType>):Array<CompilerType>
			return [for (part in types) substitute(part, owners, substitutions)];
		function one(part:CompilerType):CompilerType
			return substitute(part, owners, substitutions);
		return switch type {
			case TTypeParameter(owner, name) if (owners.indexOf(owner) >= 0):
				var replacement = substitutions.get(name);
				replacement == null ? type : replacement;
			case TNullable(element): TNullable(one(element));
			case TArray(element): TArray(one(element));
			case TIterator(element): TIterator(one(element));
			case TMap(key, value): TMap(one(key), one(value));
			case TKeyPath(root, value, writable): TKeyPath(one(root), one(value), writable);
			case TFunction(arguments, result, optional): TFunction(each(arguments), one(result), optional);
			case TInstance(kind, name, arguments): TInstance(kind, name, each(arguments));
			case TAbstract(name, arguments, representation): TAbstract(name, each(arguments), one(representation));
			default: type;
		};
	}
}
