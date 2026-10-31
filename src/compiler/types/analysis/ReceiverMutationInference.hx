package compiler.types.analysis;

import compiler.Source.SourceSpan;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstStatement;

/** Conservative syntactic proof that a value method cannot write its receiver. */
class ReceiverMutationInference extends BindingWalker {
	public static inline final PREFIX = "$receiver-readonly:";
	final fields:Map<String, Bool> = [];
	final methods:Map<String, Bool> = [];
	final getters:Map<String, Bool> = [];
	var mutates = false;

	function new(declaration:AstClass) {
		super();
		for (field in declaration.fields) if (!field.isStatic) {
			fields.set(field.name, true);
			if (field.readAccess == GetAccess || field.readAccess == DynamicAccess) getters.set(field.name, true);
		}
		for (method in declaration.methods) if (!method.isStatic) methods.set(method.name, true);
		bind("this", "$receiver");
	}

	public static function isReadOnly(declaration:AstClass, fn:AstFunction):Bool {
		if (fn.isExtern == true) return false;
		var walker = new ReceiverMutationInference(declaration);
		walker.walkFunction(fn.arguments, fn.statements);
		return !walker.mutates;
	}

	override function written(name:String, declaration:Null<String>, span:SourceSpan):Void {
		var root = BindingWalker.rootOf(name);
		if (root == "this" || (declaration == null && fields.exists(root))) mutates = true;
	}

	override function callee(name:String, declaration:Null<String>, span:SourceSpan):Void {
		if (declaration == null && methods.exists(name)) mutates = true;
		super.callee(name, declaration, span);
	}

	override function memberCall(local:String, declaration:Null<String>, method:String, span:SourceSpan):Void {
		if (local == "this" || (declaration == null && fields.exists(local))) mutates = true;
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
			case MethodCall(target, _, _, _) if (isReceiverPlace(target)): mutates = true;
			case Call(_, arguments, _), MethodCall(_, _, arguments, _):
				for (argument in arguments) if (containsReceiver(argument)) mutates = true;
			case Variable(name, _) if (resolve(name) == null && getters.exists(BindingWalker.rootOf(name))): mutates = true;
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
		if (isReceiverPlace(value)) return true;
		for (child in compiler.syntax.AstChildren.expressions(value))
			if (containsReceiver(child)) return true;
		return false;
	}
}
