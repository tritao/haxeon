package compiler.types.typing;

import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;

private typedef PayloadDependencyNode = {
	final key:String;
	final name:String;
	final parameters:Array<String>;
	final payloads:Array<CompilerType>;
	final used:Map<String, Bool>;
}

/** Find recursive enum declarations without expanding non-regular generic instances. */
class EnumRecursion {
	final session:TypingSession;
	final nodes:Map<String, PayloadDependencyNode> = [];
	final edges:Map<String, Map<String, Bool>> = [];
	final results:Map<String, Bool> = [];
	var ready = false;
	var changed = false;

	public function new(session:TypingSession) this.session = session;

	public function isRecursive(name:String):Bool {
		if (!ready) build();
		if (!results.exists(name)) {
			var root = "enum:" + name;
			results.set(name, reaches(root, root, []));
		}
		return results.get(name);
	}

	function build():Void {
		for (declaration in session.enumDecls) {
			var arguments = [for (parameter in declaration.typeParameters) TTypeParameter(declaration.name, parameter)];
			var instance = TInstance(NominalKind.Enum, declaration.name, arguments);
			add("enum:" + declaration.name, declaration.name, declaration.typeParameters,
				[for (constructor in declaration.cases) for (parameter in constructor.params)
					session.representation.enumParameterType(declaration.typeParameters, parameter, instance)]);
		}
		for (declaration in session.classDecls) {
			var arguments = [for (parameter in declaration.typeParameters) TTypeParameter(declaration.name, parameter)];
			if (!session.relations.isValueClass(TInstance(NominalKind.Class, declaration.name, arguments))) continue;
			var substitutions = session.representation.typeParameterSubstitutions(declaration.typeParameters, arguments);
			var payloads = [for (field in declaration.fields) if (!field.isStatic)
				session.representation.semanticType(session.declarations.resolvedFieldType(declaration.name, field), field.span, substitutions)];
			if (declaration.base != null) payloads.push(session.representation.semanticType(declaration.base, declaration.span, substitutions));
			add("value:" + declaration.name, declaration.name, declaration.typeParameters, payloads);
		}
		// A generic wrapper exposes only the arguments which reach a stored payload.
		// Solve that finite relation first: E<E<Rec<T>>> must not stop at the second E,
		// while a phantom argument must not make a parent recursive through a boxed child.
		do {
			changed = false;
			for (node in nodes) for (payload in node.payloads) visit(payload, node, null);
		} while (changed);
		for (node in nodes) {
			var dependencies:Map<String, Bool> = [];
			for (payload in node.payloads) visit(payload, node, dependencies);
			edges.set(node.key, dependencies);
		}
		ready = true;
	}

	function add(key:String, name:String, parameters:Array<String>, payloads:Array<CompilerType>):Void
		nodes.set(key, {key: key, name: name, parameters: parameters, payloads: payloads, used: []});

	function visit(type:CompilerType, current:PayloadDependencyNode, dependencies:Null<Map<String, Bool>>):Void switch type {
		case TTypeParameter(owner, parameter) if (owner == current.name):
			if (!current.used.exists(parameter)) { current.used.set(parameter, true); changed = true; }
		case TInstance(kind, name, arguments):
			var key = (kind == NominalKind.Enum ? "enum:" : "value:") + name;
			var node = kind == NominalKind.Enum || kind == NominalKind.Class ? nodes.get(key) : null;
			if (node != null) {
				if (dependencies != null) dependencies.set(key, true);
				for (index in 0...arguments.length)
					if (index < node.parameters.length && node.used.exists(node.parameters[index])) visit(arguments[index], current, dependencies);
			}
		case TAbstract(_, _, representation), TNullable(representation), TArray(representation), TIterator(representation):
			visit(representation, current, dependencies);
		case TMap(key, value), TKeyPath(key, value, _): visit(key, current, dependencies); visit(value, current, dependencies);
		case TFunction(arguments, result):
			for (argument in arguments) visit(argument, current, dependencies);
			visit(result, current, dependencies);
		// Managed classes and anonymous records are reference leaves, as in the IR layout planner.
		default:
	};

	function reaches(root:String, current:String, seen:Map<String, Bool>):Bool {
		if (seen.exists(current)) return false;
		seen.set(current, true);
		var dependencies = edges.get(current);
		if (dependencies != null) for (next in dependencies.keys())
			if (next == root || reaches(root, next, seen)) return true;
		return false;
	}
}
