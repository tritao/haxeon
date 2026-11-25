package compiler.semantic;

import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstField;
import compiler.syntax.Ast.AstFieldAccess;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstInterface;
import compiler.syntax.Ast.AstProgram;
import compiler.syntax.Ast.AstType;

/**
 * The methods that carry an interface's variables and properties (`interface Shape { var area(get, never):Int; var x:Int; }`).
 * An access through the interface is a call of a method of the interface, so it dispatches on the object as a method call does,
 * on every backend:
 *
 * - a `get`, `set` or `dynamic` side is its accessor, `get_x` or `set_x`, which Haxe adds to the interface too ("Field get_x
 *   needed by I is missing"), and which the implementing class declares;
 * - a dynamic method's accessors read and write its callback slot through the implementing class;
 * - a `default` side (a physical variable) is a hidden accessor, `$get_x` or `$set_x`, which every class that implements the
 *   interface is given here, reading or writing its own variable;
 * - a `null` or `never` side has no method: it cannot be accessed through the interface.
 *
 * The interface's accessors are a function of its own declaration (`implied`), added where it is canonicalized; a class's are added
 * where the program is assembled (`add`), as `ImplicitConstructors` adds constructors, since they depend on the interfaces of
 * other modules. A class records a layout dependency on each interface it implements, so a change to one retypes them.
 */
class InterfaceFieldAccessors {
	/** The metadata that marks an accessor an interface implies, not declared in source. */
	public static inline final GENERATED = "compilerGenerated";

	static inline final GET_PREFIX = "$get_";
	static inline final SET_PREFIX = "$set_";

	/** The interface method a read (`read`) or write of `field` through its interface calls, or null when that side has none. */
	public static function accessorName(field:AstField, read:Bool):Null<String>
		return switch sideOf(field, read) {
			case GetAccess, SetAccess, DynamicAccess: (read ? "get_" : "set_") + field.name;
			case DefaultAccess: (read ? GET_PREFIX : SET_PREFIX) + field.name;
			default: null;
		};

	public static function dynamicAccessorName(name:String, read:Bool):String
		return (read ? GET_PREFIX : SET_PREFIX) + name;

	static function dynamicType(method:AstFunction):AstType {
		var erased = [for (parameter in method.typeParameters ?? []) parameter => NamedType("Dynamic")];
		return ImplicitConstructors.substitute(FunctionType([
			for (argument in method.arguments)
				compiler.syntax.AstPredicates.isOptionalArgument(argument) ? NullableType(argument.type) : argument.type
		], method.result,
			[for (argument in method.arguments) compiler.syntax.AstPredicates.isOptionalArgument(argument)]), erased);
	}

	/** Whether `name` is a hidden accessor of a physical variable (`$get_x`, `$set_x`). */
	public static function isHiddenAccessor(name:String):Bool
		return StringTools.startsWith(name, GET_PREFIX) || StringTools.startsWith(name, SET_PREFIX);

	/**
	 * The access of a side of `field` as Haxe reads it: a plain `var` is `default` on both, a `final` is `default` to read and
	 * written by no one through the interface (Haxe's `ctor`, which `NullAccess` stands for here).
	 */
	public static function sideOf(field:AstField, read:Bool):AstFieldAccess {
		var written = read ? field.readAccess : field.writeAccess;
		if (written != null)
			return written;
		return !read && field.isFinal ? NullAccess : DefaultAccess;
	}

	/** The accessors implied by variables, properties, and dynamic methods. */
	public static function implied(declaration:AstInterface):Array<AstFunction> {
		var declared:Map<String, Bool> = [for (method in declaration.methods) method.name => true],
			result:Array<AstFunction> = [];
		for (method in declaration.methods)
			if (method.isDynamic == true)
				for (read in [true, false]) {
					var name = dynamicAccessorName(method.name, read);
					if (!declared.exists(name))
						result.push(accessor(name, dynamicType(method), read, true, method.span));
				}
		for (field in declaration.fields) {
			if (field.isStatic || field.type == null)
				continue;
			for (read in [true, false]) {
				var name = accessorName(field, read);
				if (name == null || declared.exists(name))
					continue;
				declared.set(name, true);
				result.push(accessor(name, field.type, read, true, field.span));
			}
		}
		return result;
	}

	/**
	 * `program` with the accessors of its interfaces' variables, on the interfaces and on the classes that implement them, those
	 * it does not have yet: the whole of it for a program no assembly gave them (`compiler.Frontend`), nothing for one that did.
	 */
	public static function withAccessors(program:AstProgram):AstProgram {
		var changed = false;
		var interfaces = [for (declaration in program.interfaces) {
			var implied = implied(declaration);
			if (implied.length == 0) declaration;
			else {
				changed = true;
				({
					name: declaration.name,
					typeParameters: declaration.typeParameters,
					typeConstraints: declaration.typeConstraints,
					bases: declaration.bases,
					documentationMetadata: declaration.documentationMetadata,
					visibility: declaration.visibility,
					fields: declaration.fields,
					methods: declaration.methods.concat(implied),
					span: declaration.span
				}:AstInterface);
			}
		}];
		var classes = program.classes.copy();
		if (add(classes, interfaces).length > 0)
			changed = true;
		return !changed ? program : {
			packageName: program.packageName,
			imports: program.imports,
			usings: program.usings,
			aliases: program.aliases,
			enums: program.enums,
			abstracts: program.abstracts,
			interfaces: interfaces,
			classes: classes,
			functions: program.functions,
			fields: program.fields
		};
	}

	/**
	 * Adds hidden accessors to the implementing classes and returns them. A base class can supply an accessor. Missing members
	 * are left to the interface check.
	 */
	public static function add(classes:Array<AstClass>, interfaces:Array<AstInterface>):Array<{
		owner:String,
		method:AstFunction
	}> {
		var indexOf:Map<String, Int> = [],
			interfaceByName:Map<String, AstInterface> =
				[for (declaration in interfaces) declaration.name => declaration];
		for (index in 0...classes.length)
			indexOf.set(classes[index].name, index);
		if (!hasStorageAccessors(interfaces))
			return [];
		var added:Array<{owner:String, method:AstFunction}> = [], done:Map<String, Bool> = [];
		function hasMethod(className:Null<String>, name:String):Bool {
			var seen:Map<String, Bool> = [];
			while (className != null && !seen.exists(className)) {
				seen.set(className, true);
				var index = indexOf.get(className);
				if (index == null)
					return false;
				for (method in classes[index].methods)
					if (method.name == name && !method.isStatic)
						return true;
				className = nominalName(classes[index].base);
			}
			return false;
		}
		function hasVariable(className:Null<String>, name:String):Bool {
			var seen:Map<String, Bool> = [];
			while (className != null && !seen.exists(className)) {
				seen.set(className, true);
				var index = indexOf.get(className);
				if (index == null)
					return false;
				for (field in classes[index].fields)
					if (field.name == name && !field.isStatic)
						return true;
				className = nominalName(classes[index].base);
			}
			return false;
		}
		function visit(className:String):Void {
			if (done.exists(className))
				return;
			done.set(className, true);
			var index = indexOf.get(className);
			if (index == null)
				return;
			var baseName = nominalName(classes[index].base);
			// A base class's accessors are inherited: it is given its own first.
			if (baseName != null)
				visit(baseName);
			var declaration = classes[index];
			if (declaration.isExtern == true)
				return;
			var methods:Array<AstFunction> = [];
			for (implemented in declaration.interfaces)
				collect(implemented, interfaceByName, [], function(member, type, read) {
					if (!hasMethod(className, member.accessor)
						&& [for (method in methods) method.name].indexOf(member.accessor) < 0
						&& (member.dynamicMethod ? hasMethod(className, member.name) : hasVariable(className,
						member.name)))
						methods.push(accessor(member.accessor, type, read, false, declaration.span, member.name));
				});
			if (methods.length == 0)
				return;
			classes[index] = withMethods(declaration, methods);
			for (method in methods)
				added.push({owner: className, method: method});
		}
		for (declaration in classes.copy())
			visit(declaration.name);
		return added;
	}

	static function hasStorageAccessors(interfaces:Array<AstInterface>):Bool {
		for (declaration in interfaces) {
			for (method in declaration.methods)
				if (method.isDynamic == true)
					return true;
			for (field in declaration.fields)
				for (read in [true, false])
					if (sideOf(field, read) == DefaultAccess)
						return true;
		}
		return false;
	}

	/**
	 * Visits storage accessors with the interface's type parameters substituted as the implementing class sees them.
	 */
	static function collect(type:AstType, interfaces:Map<String, AstInterface>, visited:Array<String>,
			found:({name: String, accessor: String, dynamicMethod: Bool}, AstType, Bool) -> Void):Void {
		var name = nominalName(type), declaration = name == null ? null : interfaces.get(name);
		if (declaration == null || visited.indexOf(declaration.name) >= 0)
			return;
		visited.push(declaration.name);
		var own:Map<String, AstType> = [];
		switch type {
			case AppliedType(_, arguments):
				for (index in 0...declaration.typeParameters.length)
					if (index < arguments.length)
						own.set(declaration.typeParameters[index], arguments[index]);
			default:
		}
		for (field in declaration.fields)
			if (!field.isStatic && field.type != null)
				for (read in [true, false]) {
					var name = accessorName(field, read);
					if (name != null && isHiddenAccessor(name))
						found({name: field.name, accessor: name, dynamicMethod: false},
							ImplicitConstructors.substitute(field.type, own), read);
				}
		for (method in declaration.methods)
			if (method.isDynamic == true)
				for (read in [true, false])
					found({name: method.name, accessor: dynamicAccessorName(method.name, read), dynamicMethod: true},
						ImplicitConstructors.substitute(dynamicType(method), own), read);
		for (base in declaration.bases)
			collect(ImplicitConstructors.substitute(base, own), interfaces, visited, found);
	}

	/**
	 * The accessor `name` of a variable of type `type`: `function get():T` or `function set(value:T):T`. An interface's has no body;
	 * a class's (`variable` is its name) reads `this.variable`, or writes it and returns the value written.
	 */
	static function accessor(name:String, type:AstType, read:Bool, isContract:Bool, span:SourceSpan,
			?variable:String):AstFunction {
		var receiver = Variable("this", span),
			statements = isContract ? [] : read ? [Return(Member(receiver, variable, span), span)] : [
				FieldAssignment(receiver, variable, Variable("value", span), span),
				Return(Variable("value", span), span)
			];
		return {
			name: name,
			isStatic: false,
			visibility: AstVisibility.Public,
			metadata: [{name: GENERATED, arguments: [], span: span}],
			arguments: read ? [] : [{name: "value", type: type, span: span}],
			result: type,
			statements: statements,
			span: span
		};
	}

	static function withMethods(declaration:AstClass, methods:Array<AstFunction>):AstClass
		return {
			name: declaration.name,
			isStruct: declaration.isStruct,
			isExtern: declaration.isExtern,
			typeParameters: declaration.typeParameters,
			typeConstraints: declaration.typeConstraints,
			visibility: declaration.visibility,
			metadata: declaration.metadata,
			base: declaration.base,
			interfaces: declaration.interfaces,
			fields: declaration.fields,
			methods: declaration.methods.concat(methods),
			span: declaration.span
		};

	static function nominalName(type:Null<AstType>):Null<String>
		return switch type {
			case NamedType(name), AppliedType(name, _): name;
			default: null;
		};
}
