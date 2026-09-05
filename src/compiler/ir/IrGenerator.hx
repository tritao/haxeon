package compiler.ir;

import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedProgram;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedStatement;
import compiler.ir.Cfg.CfgFunction;
import compiler.ir.Cfg.CfgValue;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrObject;

/** Lowers typed syntax to a mutable-local CFG; SsaBuilder owns all SSA policy. */
class IrGenerator {
	public static function generate(typed:TypedProgram):IrProgram {
		return assemble([for (fn in typed.functions) generateFunction(fn)], null, objectsFrom(typed));
	}

	public static function objectsFrom(typed:TypedProgram):Array<IrObject> {
		return [
			for (classDecl in typed.classes)
				{
					name: classDecl.name,
					base: classDecl.base,
					fields: [
						for (field in classDecl.fields)
							if (!field.isStatic) {name: field.name, type: lowerType(field.type)}
					]
				}
		];
	}

	public static function generateFunction(fn:TypedFunction):IrFunction
		return SsaBuilder.build(generateCfg(fn));

	public static function generateCfg(fn:TypedFunction):CfgFunction {
		var builder = new CfgBuilder(), localTypes:Map<String, IrType> = [];
		var arguments = [
			for (argument in implicitArguments(fn)) {
				localTypes.set(argument.name, argument.type);
				{name: argument.name, type: argument.type};
			}
		];
		arguments = arguments.concat([
			for (argument in fn.arguments) {
				var type = lowerType(argument.type);
				localTypes.set(argument.name, type);
				{name: argument.name, type: type};
			}
		]);
		lowerStatements(fn.statements, builder, localTypes);
		if (!builder.isTerminated()) {
			if (lowerType(fn.result) == Void)
				builder.returnVoid();
			else
				throw 'Function ${fn.name} does not return on every path';
		}
		return new CfgFunction(fn.name, arguments, lowerType(fn.result), builder.blocks, localTypes);
	}

	public static function assemble(functions:Array<IrFunction>, ?natives:Array<IrNative>, ?objects:Array<IrObject>):IrProgram {
		var program = new IrProgram("__entry");
		program.objects = objects == null ? [] : objects;
		program.natives.push({
			name: "__exit",
			library: "std",
			symbol: "sys_exit",
			arguments: [I32],
			result: Void
		});
		if (natives != null)
			for (native in natives)
				program.natives.push(native);
		for (fn in functions)
			program.functions.push(fn);
		var entry = new IrBuilder();
		var result = entry.call("main", [], I32);
		var exited = entry.call("__exit", [result], Void);
		entry.returnValue(exited);
		program.functions.push(new IrFunction("__entry", [], Void, entry.blocks));
		return program;
	}

	static function lowerStatements(statements:Array<TypedStatement>, builder:CfgBuilder, localTypes:Map<String, IrType>):Void {
		for (statement in statements) {
			if (builder.isTerminated())
				break;
			switch statement {
				case TVar(name, initializer, _):
					localTypes.set(name, lowerType(initializer.type));
					builder.store(name, lowerExpression(initializer, builder, localTypes));
				case TAssign(name, value, _):
					builder.store(name, lowerExpression(value, builder, localTypes));
				case TFieldAssign(object, name, value, _):
					builder.fieldSet(lowerExpression(object, builder, localTypes), name, lowerExpression(value, builder, localTypes));
				case TReturn(expression, _):
					builder.returnValue(lowerExpression(expression, builder, localTypes));
				case TIf(condition, thenBranch, elseBranch, _):
					var thenBlock = builder.createBlock(),
						elseBlock = builder.createBlock(),
						joinBlock = builder.createBlock();
					builder.branch(lowerExpression(condition, builder, localTypes), thenBlock, elseBlock);
					builder.select(thenBlock);
					lowerStatements(thenBranch, builder, localTypes);
					var thenActive = !builder.isTerminated();
					if (thenActive)
						builder.jump(joinBlock);
					builder.select(elseBlock);
					lowerStatements(elseBranch, builder, localTypes);
					var elseActive = !builder.isTerminated();
					if (elseActive)
						builder.jump(joinBlock);
					if (thenActive || elseActive)
						builder.select(joinBlock);
				case TWhile(condition, body, _):
					var conditionBlock = builder.createBlock(),
						bodyBlock = builder.createBlock(),
						afterBlock = builder.createBlock();
					builder.jump(conditionBlock);
					builder.select(conditionBlock);
					builder.branch(lowerExpression(condition, builder, localTypes), bodyBlock, afterBlock);
					builder.select(bodyBlock);
					lowerStatements(body, builder, localTypes);
					if (!builder.isTerminated())
						builder.jump(conditionBlock);
					builder.select(afterBlock);
				case TExpression(expression, _):
					lowerExpression(expression, builder, localTypes);
			}
		}
	}

	static function lowerExpression(expression:TypedExpression, builder:CfgBuilder, localTypes:Map<String, IrType>):CfgValue
		return switch expression.expression {
			case TIntLiteral(value): builder.constInt(value);
			case TFloatLiteral(value): builder.constFloat(value);
			case TStringLiteral(value): builder.constString(value);
			case TLocal(name):
				var type = localTypes.get(name);
				if (type == null)
					throw 'Missing typed local "$name"';
				builder.load(name, type);
			case TAdd(a, b): builder.add(lowerExpression(a, builder, localTypes), lowerExpression(b, builder, localTypes));
			case TSub(a, b): builder.sub(lowerExpression(a, builder, localTypes), lowerExpression(b, builder, localTypes));
			case TMul(a, b): builder.mul(lowerExpression(a, builder, localTypes), lowerExpression(b, builder, localTypes));
			case TDiv(a, b): builder.div(lowerExpression(a, builder, localTypes), lowerExpression(b, builder, localTypes));
			case TLess(a, b): builder.less(lowerExpression(a, builder, localTypes), lowerExpression(b, builder, localTypes));
			case TLessEqual(a, b): builder.lessEqual(lowerExpression(a, builder, localTypes), lowerExpression(b, builder, localTypes));
			case TEqual(a, b): builder.equal(lowerExpression(a, builder, localTypes), lowerExpression(b, builder, localTypes));
			case TCall(name, args): builder.call(name, [for (arg in args) lowerExpression(arg, builder, localTypes)], lowerType(expression.type));
			case TNew(typeName, args):
				var object = builder.newObject(typeName);
				var constructorArgs = [object];
				for (arg in args)
					constructorArgs.push(lowerExpression(arg, builder, localTypes));
				builder.call('$typeName.new', constructorArgs, Void);
				object;
			case TField(object, name): builder.fieldGet(lowerExpression(object, builder, localTypes), name, lowerType(expression.type));
			case TMethodCall(object, name, args):
				var receiver = lowerExpression(object, builder, localTypes),
					callArgs = [receiver];
				for (arg in args)
					callArgs.push(lowerExpression(arg, builder, localTypes));
				builder.call(name, callArgs, lowerType(expression.type));
		}

	static function implicitArguments(fn:TypedFunction):Array<{name:String, type:IrType}> {
		if (fn.owner == null || fn.isStatic)
			return [];
		return [{name: "this", type: Obj(fn.owner)}];
	}

	public static function lowerType(type:CompilerType):IrType
		return switch type {
			case TInt: I32;
			case TBool: Bool;
			case TFloat: F64;
			case TString: Bytes;
			case TVoid: Void;
			case TClass(name): Obj(name);
		};
}
