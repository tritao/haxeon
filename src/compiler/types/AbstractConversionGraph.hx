package compiler.types;

import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.DiagnosticCode;
import compiler.core.InternalError;
import compiler.semantic.SemanticSignature;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;

/** How a value becomes another type by an abstract's implicit conversion (`AbstractConversionGraph.route`). */
enum AbstractConversionRoute {
	/** The expected abstract's `@:from` function `name`, called with the value converted to its `argument`. */
	FromFunction(name:String, argument:CompilerType);

	/** A type the expected abstract is declared `from`: the value converted to `declared` is the abstract. */
	FromType(declared:CompilerType);

	/** The value's abstract's `@:to` method `method`, whose `result` converts to the expected type. */
	ToFunction(method:String, result:CompilerType);

	/** A type the value's abstract is declared `to`: the abstract is a `declared`, which converts to the expected type. */
	ToType(declared:CompilerType);
}

private typedef ConversionEdge = {
	final source:String;
	final target:String;
}

/** Indexed direct conversions plus declaration-time validation for future-safe chaining. */
class AbstractConversionGraph {
	final declarations:DeclarationIndex;
	final fromEdges:Array<ConversionEdge> = [];
	final toEdges:Array<ConversionEdge> = [];
	final spans:Map<String, compiler.core.Source.SourceSpan> = [];

	public function new(declarations:DeclarationIndex, shouldValidate:Bool) {
		this.declarations = declarations;

		if (shouldValidate) {
			validate();
		}
	}

	public function validate():Void {
		// Module-local indexes are incomplete until dependency discovery finishes.
		fromEdges.resize(0);
		toEdges.resize(0);
		spans.clear();
		for (name in declarations.abstractNames()) {
			var decl = declarations.abstractDeclaration(name);
			if (decl == null)
				throw new InternalError('Abstract declaration "$name" disappeared during conversion indexing');
			var substitutions = abstractSubstitutions(decl.name, decl.typeParameters),
				owner = abstractNode(decl.name, [for (index in 0...decl.typeParameters.length) '$' + '$index']);
			spans.set(owner, decl.span);
			for (type in decl.fromTypes)
				fromEdges.push({
					source: node(declarations.resolve(type, decl.span, substitutions), decl.name, decl.typeParameters),
					target: owner
				});
			for (type in decl.toTypes)
				toEdges.push({
					source: owner,
					target: node(declarations.resolve(type, decl.span, substitutions), decl.name, decl.typeParameters)
				});
			for (method in decl.methods) {
				var metadata = method.metadata;
				if (metadata == null)
					continue;
				for (entry in metadata)
					switch entry.name {
						case "from" if (method.isStatic && method.arguments.length == 1):
							fromEdges.push({
								source: node(declarations.resolve(method.arguments[0].type, method.span, substitutions),
									decl.name, decl.typeParameters),
								target: owner
							});
						case "to" if (!method.isStatic && method.arguments.length == 0):
							toEdges.push({
								source: owner,
								target: node(declarations.types.resultType(method, substitutions), decl.name,
									decl.typeParameters)
							});
						default:
					}
			}
		}
		validateDirection("from", fromEdges);
		validateDirection("to", toEdges);
	}

	public function allows(actual:CompilerType, expected:CompilerType):Bool
		return route(actual, expected) != null;

	/**
	 * How a value of `actual` becomes an `expected` by an abstract's implicit conversion, as Haxe casts it: through the expected
	 * abstract's `from` conversions, else the actual abstract's `to` conversions. Of each, a `@:from` or `@:to` function first, one
	 * whose type is the value's before one the value unifies with, then a `from` or `to` type. Null when there is none.
	 *
	 * The value meets a conversion's type as Haxe unifies it there: the same type, or, when the other side of the conversion is
	 * not itself an abstract (Haxe's core types and classes are not), Int as a Float and a class as its base class or interface.
	 * So `var r:Root = 81` converts through `from Float`, but one abstract never through another.
	 */
	public function route(actual:CompilerType, expected:CompilerType):Null<AbstractConversionRoute> {
		var from = switch expected {
			case TAbstract(name, arguments, _): routeFrom(actual, name, arguments);
			default: null;
		};
		return from != null ? from : switch actual {
			case TAbstract(name, arguments, _): routeTo(name, arguments, expected);
			default: null;
		};
	}

	/** The representation is an expected source only when a type-level `from` explicitly accepts it. */
	public function expectedRepresentation(expected:CompilerType):Null<CompilerType> {
		return switch expected {
			case TAbstract(name, arguments, representation):
				switch routeFrom(representation, name, arguments) {
					case FromType(declared) if (TypeRelations.equals(declared, representation)): representation;
					default: null;
				}
			default: null;
		};
	}

	function routeFrom(actual:CompilerType, name:String, arguments:Array<CompilerType>):Null<AbstractConversionRoute> {
		var decl = declarations.abstractDeclaration(name);
		if (decl == null)
			return null;
		var substitutions = appliedSubstitutions(decl.typeParameters, arguments),
			transitive = !isAbstract(actual);
		for (exact in [true, false])
			for (method in decl.methods)
				if (method.isStatic && method.arguments.length == 1 && hasMetadata(method, "from")) {
					var argument = declarations.resolve(method.arguments[0].type, method.span, substitutions);
					if (meets(actual, argument, !exact && transitive))
						return FromFunction(name + "." + method.name, argument);
				}
		for (exact in [true, false])
			for (type in decl.fromTypes) {
				var declared = declarations.resolve(type, decl.span, substitutions);
				if (meets(actual, declared, !exact && transitive))
					return FromType(declared);
			}
		return null;
	}

	function routeTo(name:String, arguments:Array<CompilerType>, expected:CompilerType):Null<AbstractConversionRoute> {
		var decl = declarations.abstractDeclaration(name);
		if (decl == null)
			return null;
		var substitutions = appliedSubstitutions(decl.typeParameters, arguments),
			transitive = !isAbstract(expected);
		for (exact in [true, false])
			for (method in decl.methods)
				if (!method.isStatic && method.arguments.length == 0 && hasMetadata(method, "to")) {
					var result = declarations.types.resultType(method, substitutions);
					if (meets(result, expected, !exact && transitive))
						return ToFunction(method.name, result);
				}
		for (exact in [true, false])
			for (type in decl.toTypes) {
				var declared = declarations.resolve(type, decl.span, substitutions);
				if (meets(declared, expected, !exact && transitive))
					return ToType(declared);
			}
		return null;
	}

	/** Whether a value of `actual` is a `target`: the same type, or, when `widening`, Int as a Float or a class as its base. */
	function meets(actual:CompilerType, target:CompilerType, widening:Bool):Bool
		return TypeRelations.equals(actual, target)
			|| widening && (actual.match(TInt) && target.match(TFloat) || isNominal(actual) && isNominal(target)
			&& declarations.inheritance.reaches(actual, target));

	static function isAbstract(type:CompilerType):Bool
		return type.match(TAbstract(_, _, _));

	static function isNominal(type:CompilerType):Bool
		return switch type {
			case TInstance(NominalKind.Class | NominalKind.Interface, _, _): true;
			default: false;
		};

	static function hasMetadata(method:compiler.syntax.Ast.AstFunction, name:String):Bool {
		var metadata = method.metadata;
		if (metadata != null)
			for (entry in metadata)
				if (entry.name == name)
					return true;
		return false;
	}

	function validateDirection(direction:String, edges:Array<ConversionEdge>):Void {
		var adjacency:Map<String, Array<String>> = [];
		for (edge in edges) {
			var targets = adjacency.get(edge.source);
			if (targets == null) {
				targets = [];
				adjacency.set(edge.source, targets);
			}
			targets.push(edge.target);
		}
		for (targets in adjacency)
			targets.sort(Reflect.compare);
		var sources = [for (source in adjacency.keys()) source];
		sources.sort(Reflect.compare);
		var visiting:Map<String, Bool> = [], visited:Map<String, Bool> = [];
		for (source in sources)
			visit(direction, source, adjacency, visiting, visited);
		for (source in sources) {
			var paths:Map<String, Int> = [];
			countPaths(source, adjacency, paths);
			for (target => count in paths)
				if (target != source && count > 1)
					fail('Ambiguous $direction conversion paths from "${display(source)}" to "${display(target)}"',
						source);
		}
	}

	function visit(direction:String, current:String, adjacency:Map<String, Array<String>>, visiting:Map<String, Bool>,
			visited:Map<String, Bool>):Void {
		if (visiting.exists(current))
			fail('Cyclic $direction conversion involving "${display(current)}"', current);
		if (visited.exists(current))
			return;
		visiting.set(current, true);
		var targets = adjacency.get(current);
		if (targets != null)
			for (target in targets)
				visit(direction, target, adjacency, visiting, visited);
		visiting.remove(current);
		visited.set(current, true);
	}

	static function countPaths(current:String, adjacency:Map<String, Array<String>>, paths:Map<String, Int>):Void {
		var targets = adjacency.get(current);
		if (targets == null)
			return;
		for (target in targets) {
			var count = paths.exists(target) ? paths.get(target) : 0;
			if (count < 2) {
				paths.set(target, count + 1);
				countPaths(target, adjacency, paths);
			}
		}
	}

	static function abstractSubstitutions(owner:String, parameters:Array<String>):Map<String, CompilerType>
		return [for (parameter in parameters) parameter => TTypeParameter(owner, parameter)];

	static function appliedSubstitutions(parameters:Array<String>,
			arguments:Array<CompilerType>):Map<String, CompilerType> {
		var result:Map<String, CompilerType> = [];
		for (index in 0...parameters.length)
			result.set(parameters[index], arguments[index]);
		return result;
	}

	static function node(type:CompilerType, owner:String, parameters:Array<String>):String
		return switch type {
			case TAbstract(name, arguments, _): abstractNode(name,
				[for (argument in arguments) normalizedType(argument, owner, parameters)]);
			default: "type:" + normalizedType(type, owner, parameters);
		};

	static function abstractNode(name:String, arguments:Array<String>):String
		return "abstract:" + name + (arguments.length == 0 ? "" : '<${arguments.join(",")}>');

	static function normalizedType(type:CompilerType, owner:String, parameters:Array<String>):String {
		var result = SemanticSignature.type(type);
		for (index in 0...parameters.length)
			result = StringTools.replace(result, 'type-parameter:$owner:${parameters[index]}', '$' + '$index');
		return result;
	}

	static function display(node:String):String {
		var separator = node.indexOf(":");
		return separator < 0 ? node : node.substring(separator + 1);
	}

	function fail(message:String, node:String):Void {
		var span = spans.get(node);
		if (span == null) {
			var names = [for (name in declarations.abstractNames()) name];
			names.sort(Reflect.compare);
			if (names.length == 0)
				throw new InternalError(message);
			var name = names[0];
			var declaration = declarations.abstractDeclaration(name);
			if (declaration == null)
				throw new InternalError(message);
			span = declaration.span;
		}
		throw new CompileError(new Diagnostic(DiagnosticCode.DECLARATION_OR_MODIFIER, message, span));
	}
}
