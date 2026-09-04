package compiler.types;

import compiler.Ast;
import compiler.Ast.AstExpression;
import compiler.Ast.AstFunction;
import compiler.Ast.AstProgram;
import compiler.Ast.AstStatement;
import compiler.Ast.AstType;
import compiler.Ast.AstClass;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedClass;
import compiler.types.TypedAst.TypedField;
import compiler.types.TypedAst.TypedProgram;
import compiler.types.TypedAst.TypedStatement;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceSpan;

class Typer {
	final signatures:Map<String, AstFunction> = [];
	final externals:Map<String, {arguments:Array<CompilerType>, result:CompilerType}>;

	public static function type(program:AstProgram):TypedProgram
		return new Typer(null).typeProgram(program, null);

	public static function typeSelected(program:AstProgram, selected:Map<String, Bool>,
			?externals:Map<String, {arguments:Array<CompilerType>, result:CompilerType}>):TypedProgram
		return new Typer(externals).typeProgram(program, selected);

	function new(externals)
		this.externals = externals == null ? [] : externals;

	function typeProgram(program:AstProgram, selected:Null<Map<String, Bool>>):TypedProgram {
		var classes:Map<String, AstClass> = [];
		for (classDecl in program.classes) {
			if (classes.exists(classDecl.name))
				fail("E1000", 'Duplicate class "${classDecl.name}"', classDecl.span);
			classes.set(classDecl.name, classDecl);
		}
		for (fn in program.functions) {
			if (signatures.exists(fn.name))
				fail("E1000", 'Duplicate function "${fn.name}"', fn.span);
			if (externals.exists(fn.name))
				fail("E1000", 'Function "${fn.name}" conflicts with a registered native', fn.span);
			signatures.set(fn.name, fn);
		}
		var main = signatures.get("main");
		if (main == null || main.arguments.length != 0 || lowerType(main.result) != TInt)
			throw "Program must define function main():Int";
		return {
			classes: [for (classDecl in program.classes) typeClass(classDecl, classes)],
			functions: [
				for (fn in program.functions)
					if (selected == null || selected.exists(fn.name)) typeFunction(fn)
			]
		};
	}

	function typeClass(classDecl:AstClass, classes:Map<String, AstClass>):TypedClass {
		var fields = [], fieldNames:Map<String, Bool> = [];
		for (field in classDecl.fields) {
			if (fieldNames.exists(field.name))
				fail("E1000", 'Duplicate field "${classDecl.name}.${field.name}"', field.span);
			var type = lowerType(field.type);
			if (type == TVoid)
				fail("E1002", 'Field "${classDecl.name}.${field.name}" cannot have type Void', field.span);
			fieldNames.set(field.name, true);
			fields.push({
				name: field.name,
				type: type,
				isStatic: field.isStatic,
				isFinal: field.isFinal,
				span: field.span
			});
		}
		return {
			name: classDecl.name,
			base: classDecl.base,
			fields: fields,
			methods: [for (method in classDecl.methods) typeFunction(method, classDecl.name + ".")],
			span: classDecl.span
		};
	}

	function typeFunction(fn:AstFunction, ?prefix:String = ""):TypedFunction {
		var scope = new Scope();
		var arguments = [];
		for (argument in fn.arguments) {
			var type = lowerType(argument.type);
			scope.define(argument.name, type, argument.span);
			arguments.push({name: argument.name, type: type});
		}
		var result = lowerType(fn.result);
		var statements = typeStatements(fn.statements, scope, result);
		if (result != TVoid && !alwaysReturns(statements))
			fail("E1006", 'Function ${fn.name} does not return on every path', fn.span);
		return {
			name: prefix + fn.name,
			arguments: arguments,
			result: result,
			statements: statements,
			span: fn.span
		};
	}

	function typeStatements(statements:Array<AstStatement>, scope:Scope, result:CompilerType):Array<TypedStatement> {
		var output = [];
		for (statement in statements) {
			if (alwaysReturns(output))
				fail("E1012", "Unreachable statement", statementSpan(statement));
			switch statement {
				case VarDeclaration(name, declared, initializer, span):
					var value = typeExpression(initializer, scope);
					if (declared != null && lowerType(declared) != value.type)
						fail("E1002", 'Type mismatch for local "$name"', span);
					scope.define(name, value.type, span);
					output.push(TVar(name, value, span));
				case Return(expression, span):
					var value = typeExpression(expression, scope);
					if (value.type != result)
						fail("E1003", "Return type mismatch", span);
					output.push(TReturn(value, span));
				case Assignment(name, expression, span):
					var expected = scope.resolve(name);
					if (expected == null)
						fail("E1005", 'Unknown variable "$name"', span);
					var value = typeExpression(expression, scope);
					if (value.type != expected)
						fail("E1002", 'Type mismatch for local "$name"', span);
					output.push(TAssign(name, value, span));
				case If(condition, thenBranch, elseBranch, span):
					var typedCondition = typeExpression(condition, scope);
					if (typedCondition.type != TBool)
						fail("E1004", "If condition must be Bool", span);
					output.push(TIf(typedCondition, typeStatements(thenBranch, new Scope(scope), result),
						typeStatements(elseBranch, new Scope(scope), result), span));
				case While(condition, body, span):
					var typedCondition = typeExpression(condition, scope);
					if (typedCondition.type != TBool)
						fail("E1004", "While condition must be Bool", span);
					output.push(TWhile(typedCondition, typeStatements(body, new Scope(scope), result), span));
				case Expression(expression, span):
					output.push(TExpression(typeExpression(expression, scope), span));
			}
		}
		return output;
	}

	function typeExpression(expression:AstExpression, scope:Scope):TypedExpression
		return switch expression {
			case IntegerLiteral(value, span): new TypedExpression(TIntLiteral(value), TInt, span);
			case FloatLiteral(value, span): new TypedExpression(TFloatLiteral(value), TFloat, span);
			case StringLiteral(value, span): new TypedExpression(TStringLiteral(value), TString, span);
			case Variable(name, span):
				var type = scope.resolve(name);
				if (type == null)
					fail("E1005", 'Unknown variable "$name"', span);
				new TypedExpression(TLocal(name), type, span);
			case Add(left, right, span): arithmetic(left, right, scope, true, span);
			case Sub(left, right, span): arithmetic(left, right, scope, false, span);
			case Mul(left, right, span): numeric(left, right, scope, 2, span);
			case Div(left, right, span): numeric(left, right, scope, 3, span);
			case Less(left, right, span): comparison(left, right, scope, 0, span);
			case LessEqual(left, right, span): comparison(left, right, scope, 1, span);
			case Equal(left, right, span): comparison(left, right, scope, 2, span);
			case Call(name, arguments, span):
				var signature = signatures.get(name);
				var external = externals.get(name),
					expectedArguments = signature == null ? (external == null ? null : external.arguments) : [for (argument in signature.arguments) lowerType(argument.type)],
					result = signature == null ? (external == null ? null : external.result) : lowerType(signature.result);
				if (expectedArguments == null)
					fail("E1007", 'Unknown function "$name"', span);
				if (arguments.length != expectedArguments.length)
					fail("E1008", 'Function "$name" expects ${expectedArguments.length} arguments, got ${arguments.length}', span);
				var typed = [for (argument in arguments) typeExpression(argument, scope)];
				for (i in 0...typed.length)
					if (typed[i].type != expectedArguments[i])
						fail("E1009", 'Argument ${i + 1} to "$name" has the wrong type', typed[i].span);
				new TypedExpression(TCall(name, typed), result, span);
		}

	function arithmetic(a, b, scope, add, span):TypedExpression {
		var left = typeExpression(a, scope), right = typeExpression(b, scope);
		if (left.type != right.type || (left.type != TInt && left.type != TFloat))
			fail("E1010", "Arithmetic requires matching Int or Float operands", span);
		return new TypedExpression(add ? TAdd(left, right) : TSub(left, right), left.type, span);
	}

	function numeric(a, b, scope, operation, span):TypedExpression {
		var left = typeExpression(a, scope), right = typeExpression(b, scope);
		if (left.type != right.type || (left.type != TInt && left.type != TFloat))
			fail("E1010", "Arithmetic requires matching Int or Float operands", span);
		return new TypedExpression(operation == 2 ? TMul(left, right) : TDiv(left, right), left.type, span);
	}

	function comparison(a, b, scope, operation, span):TypedExpression {
		var left = typeExpression(a, scope), right = typeExpression(b, scope);
		if (left.type != TInt || right.type != TInt)
			fail("E1011", "Comparison requires Int operands", span);
		return new TypedExpression(switch operation {
			case 0: TLess(left, right);
			case 1: TLessEqual(left, right);
			default: TEqual(left, right);
		}, TBool, span);
	}

	static function alwaysReturns(statements:Array<TypedStatement>):Bool {
		for (statement in statements)
			switch statement {
				case TReturn(_, _):
					return true;
				case TIf(_, yes, no, _):
					if (no.length > 0 && alwaysReturns(yes) && alwaysReturns(no))
						return true;
				default:
			}
		return false;
	}

	static function lowerType(type:AstType):CompilerType
		return switch type {
			case IntType: TInt;
			case BoolType: TBool;
			case FloatType: TFloat;
			case StringType: TString;
			case VoidType: TVoid;
			case NamedType(name): throw 'Named type "$name" is not implemented yet';
		};

	static function statementSpan(statement:AstStatement):SourceSpan
		return switch statement {
			case VarDeclaration(_, _, _, span), Assignment(_, _, span), Return(_, span), If(_, _, _, span), While(_, _, span), Expression(_, span): span;
		}

	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));
}
