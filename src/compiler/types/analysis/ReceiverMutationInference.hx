package compiler.types.analysis;

import compiler.Source.SourceSpan;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;

/** Conservative syntactic proof that a value method cannot write its receiver. */
class ReceiverMutationInference extends BindingWalker {
	public static inline final PREFIX = "$receiver-readonly:";
	final fields:Map<String, Bool> = [];
	final scalarFields:Map<String, Bool> = [];
	final methods:Map<String, AstFunction> = [];
	final getters:Map<String, Bool> = [];
	final declaration:AstClass;
	final visiting:Map<String, Bool>;
	var mutates = false;

	function new(declaration:AstClass, visiting:Map<String, Bool>) {
		super();
		this.declaration = declaration;
		this.visiting = visiting;
		for (field in declaration.fields) if (!field.isStatic) {
			fields.set(field.name, true);
			if (field.readAccess == GetAccess || field.readAccess == DynamicAccess) getters.set(field.name, true);
			else switch field.type {
				case IntType, FloatType, BoolType, StringType: scalarFields.set(field.name, true);
				default:
			}
		}
		for (method in declaration.methods) if (!method.isStatic) methods.set(method.name, method);
		bind("this", "$receiver");
	}

	public static function isReadOnly(declaration:AstClass, fn:AstFunction):Bool {
		return proveReadOnly(declaration, fn, []);
	}

	static function proveReadOnly(declaration:AstClass, fn:AstFunction, visiting:Map<String, Bool>):Bool {
		if (fn.isExtern == true) return false;
		// Struct methods dispatch to this declaration, so a recursive cycle is safe only if every body in it is safe.
		if (visiting.exists(fn.name)) return true;
		visiting.set(fn.name, true);
		var walker = new ReceiverMutationInference(declaration, visiting);
		walker.walkFunction(fn.arguments, fn.statements);
		visiting.remove(fn.name);
		return !walker.mutates;
	}

	function receiverCall(name:String):Void {
		var method = methods.get(name);
		if (method == null || !proveReadOnly(declaration, method, visiting)) mutates = true;
	}

	override function written(name:String, declaration:Null<String>, span:SourceSpan):Void {
		var root = BindingWalker.rootOf(name);
		if (root == "this" || (declaration == null && fields.exists(root))) mutates = true;
	}

	override function callee(name:String, declaration:Null<String>, span:SourceSpan):Void {
		if (declaration == null && methods.exists(name)) receiverCall(name);
		super.callee(name, declaration, span);
	}

	override function memberCall(local:String, declaration:Null<String>, method:String, span:SourceSpan):Void {
		if (local == "this") receiverCall(method);
		else if (declaration == null && fields.exists(local)) mutates = true;
		super.memberCall(local, declaration, method, span);
	}

	override function statement(value:AstStatement):Void {
		switch value {
			case FieldAssignment(object, _, _, _), IndexAssignment(object, _, _, _) if (isReceiverPlace(object)): mutates = true;
			default:
		}
		super.statement(value);
	}

	override function expression(value:AstExpression):Void {
		switch value {
			case PostfixIncrement(target, _, _) if (isReceiverPlace(target)): mutates = true;
			case MethodCall(Variable("this", _), name, arguments, _):
				receiverCall(name);
				for (argument in arguments) if (containsReceiver(argument)) mutates = true;
			case MethodCall(target, _, _, _) if (isReceiverPlace(target)): mutates = true;
			case Call(_, arguments, _), MethodCall(_, _, arguments, _):
				for (argument in arguments) if (containsReceiver(argument)) mutates = true;
			case Variable(name, _) if (resolve(name) == null && getters.exists(BindingWalker.rootOf(name))): mutates = true;
			case Variable(name, _) if (StringTools.startsWith(name, "this.") && getters.exists(name.substr(5))): mutates = true;
			case Member(object, field, _) if (isReceiverPlace(object) && getters.exists(field)): mutates = true;
			default:
		}
		super.expression(value);
	}

	function isReceiverPlace(value:AstExpression):Bool
		return switch value {
			case Variable(name, _):
				var root = BindingWalker.rootOf(name);
				root == "this" || (resolve(name) == null && fields.exists(root));
			case Member(object, _, _), Index(object, _, _): isReceiverPlace(object);
			default: false;
		};

	function containsReceiver(value:AstExpression):Bool {
		// Passing a primitive field passes its value, not a writable alias to the receiver.
		// Keep the proof conservative for inferred and composite field types.
		switch value {
			case Variable(name, _) if (name == BindingWalker.rootOf(name) && resolve(name) == null && scalarFields.exists(name)):
				return false;
			case Variable(name, _) if (StringTools.startsWith(name, "this.") && scalarFields.exists(name.substr(5))):
				return false;
			case Member(Variable("this", _), name, _) if (scalarFields.exists(name)):
				return false;
			default:
		}
		if (isReceiverPlace(value)) return true;
		for (child in compiler.syntax.AstChildren.expressions(value))
			if (containsReceiver(child)) return true;
		return false;
	}
}
