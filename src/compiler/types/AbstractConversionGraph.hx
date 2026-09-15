package compiler.types;

import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.semantic.SemanticSignature;
import compiler.types.Type.CompilerType;

private typedef ConversionEdge = {
	final source:String;
	final target:String;
}

/** Indexed direct conversions plus declaration-time validation for future-safe chaining. */
class AbstractConversionGraph {
	final declarations:DeclarationIndex;
	final fromEdges:Array<ConversionEdge> = [];
	final toEdges:Array<ConversionEdge> = [];
	final spans:Map<String, compiler.Source.SourceSpan> = [];

	public function new(declarations:DeclarationIndex, shouldValidate:Bool) {
		this.declarations = declarations;
		for (name in declarations.abstracts.keys()) {
			if (!declarations.abstracts.exists(name))
				throw 'Abstract declaration "$name" disappeared during conversion indexing';
			var decl = declarations.abstracts.get(name),
				substitutions = abstractSubstitutions(decl.name, decl.typeParameters),
				owner = abstractNode(decl.name, [for (index in 0...decl.typeParameters.length) '$' + '$index']);
			spans.set(owner, decl.span);
			for (type in decl.fromTypes) {
				var resolved = resolveConversionType(type, decl.span, substitutions);
				if (resolved != null)
					fromEdges.push({source: node(resolved, decl.name, decl.typeParameters), target: owner});
			}
			for (type in decl.toTypes) {
				var resolved = resolveConversionType(type, decl.span, substitutions);
				if (resolved != null)
					toEdges.push({source: owner, target: node(resolved, decl.name, decl.typeParameters)});
			}
			for (method in decl.methods) {
				var metadata = method.metadata;
				if (metadata == null)
					continue;
				var fromType = method.arguments.length == 1 ? resolveConversionType(method.arguments[0].type, method.span, substitutions) : null,
					toType = method.arguments.length == 0 ? resolveConversionType(method.result, method.span, substitutions) : null;
				for (entry in metadata)
					switch entry.name {
						case "from" if (method.isStatic && fromType != null):
							fromEdges.push({
								source: node(fromType, decl.name, decl.typeParameters),
								target: owner
							});
						case "to" if (!method.isStatic && toType != null):
							toEdges.push({
								source: owner,
								target: node(toType, decl.name, decl.typeParameters)
							});
						default:
					}
			}
		}
		if (shouldValidate) {
			validate();
		}
	}

	public function validate():Void {
		validateDirection("from", fromEdges);
		validateDirection("to", toEdges);
	}

	public function allows(actual:CompilerType, expected:CompilerType):Bool
		return switch expected {
			case TAbstract(name, arguments, _): declaredFrom(actual, name, arguments);
			default:
				switch actual {
					case TAbstract(name, arguments, _): declaredTo(name, arguments, expected);
					default: false;
				}
		};

	function declaredFrom(actual:CompilerType, name:String, arguments:Array<CompilerType>):Bool {
		if (!declarations.abstracts.exists(name))
			return false;
		var decl = declarations.abstracts.get(name),
			substitutions = appliedSubstitutions(decl.typeParameters, arguments);
		for (type in decl.fromTypes) {
			var resolved = resolveConversionType(type, decl.span, substitutions);
			if (resolved != null && TypeRelations.equals(actual, resolved))
				return true;
		}
		for (method in decl.methods) {
			var metadata = method.metadata;
			if (metadata == null || !method.isStatic || method.arguments.length != 1)
				continue;
			var resolved = resolveConversionType(method.arguments[0].type, method.span, substitutions);
			for (entry in metadata)
				if (entry.name == "from"
					&& resolved != null && TypeRelations.equals(actual, resolved))
					return true;
		}
		return false;
	}

	function declaredTo(name:String, arguments:Array<CompilerType>, expected:CompilerType):Bool {
		if (!declarations.abstracts.exists(name))
			return false;
		var decl = declarations.abstracts.get(name),
			substitutions = appliedSubstitutions(decl.typeParameters, arguments);
		for (type in decl.toTypes) {
			var resolved = resolveConversionType(type, decl.span, substitutions);
			if (resolved != null && TypeRelations.equals(expected, resolved))
				return true;
		}
		for (method in decl.methods) {
			var metadata = method.metadata;
			if (metadata == null || method.isStatic || method.arguments.length != 0)
				continue;
			var resolved = resolveConversionType(method.result, method.span, substitutions);
			for (entry in metadata)
				if (entry.name == "to" && resolved != null && TypeRelations.equals(expected, resolved))
					return true;
		}
		return false;
	}

	/** Resolve conversion endpoints without allowing one incomplete endpoint to
	 * abort construction of the rest of a recovered semantic index. */
	function resolveConversionType(type:compiler.syntax.Ast.AstType, span:compiler.Source.SourceSpan,
		substitutions:Map<String, CompilerType>):Null<CompilerType> {
		try {
			return declarations.resolve(type, span, substitutions);
		}
		catch (error:Dynamic) {
			if (!declarations.isRecoveryMode())
				throw error;
			if (Std.isOfType(error, CompileError))
				declarations.recordRecoveryDiagnostic((cast error : CompileError).diagnostic);
			else
				declarations.recordRecoveryDiagnostic(new Diagnostic("E0002", "Unable to resolve recovered abstract conversion", span));
			return null;
		}
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
					fail('Ambiguous $direction conversion paths from "${display(source)}" to "${display(target)}"', source);
		}
	}

	function visit(direction:String, current:String, adjacency:Map<String, Array<String>>, visiting:Map<String, Bool>, visited:Map<String, Bool>):Void {
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

	static function appliedSubstitutions(parameters:Array<String>, arguments:Array<CompilerType>):Map<String, CompilerType> {
		var result:Map<String, CompilerType> = [];
		for (index in 0...parameters.length)
			result.set(parameters[index], arguments[index]);
		return result;
	}

	static function node(type:CompilerType, owner:String, parameters:Array<String>):String
		return switch type {
			case TAbstract(name, arguments, _): abstractNode(name, [for (argument in arguments) normalizedType(argument, owner, parameters)]);
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
			var names = [for (name in declarations.abstracts.keys()) name];
			names.sort(Reflect.compare);
			if (names.length == 0)
				throw message;
			var name = names[0];
			if (!declarations.abstracts.exists(name))
				throw message;
			span = declarations.abstracts.get(name).span;
		}
		throw new CompileError(new Diagnostic("E1007", message, span));
	}
}
