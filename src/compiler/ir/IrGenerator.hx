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
import compiler.ir.Ir.IrInterface;

/** Lowers typed syntax to a mutable-local CFG; SsaBuilder owns all SSA policy. */
class IrGenerator {
	public static function generate(typed:TypedProgram):IrProgram {
		return assemble([for (fn in typed.functions) generateFunction(fn)], null, objectsFrom(typed), interfacesFrom(typed));
	}

	public static function interfacesFrom(typed:TypedProgram):Array<IrInterface> {
		return [
			for (interfaceDecl in typed.interfaces)
				{
					name: interfaceDecl.name,
					bases: interfaceDecl.bases,
					methods: [
						for (method in interfaceDecl.methods)
							{name: method.name, arguments: [for (argument in method.arguments) lowerType(argument)], result: lowerType(method.result)}
					]
				}
		];
	}

	public static function objectsFrom(typed:TypedProgram):Array<IrObject> {
		return [
			for (classDecl in typed.classes)
				{
					name: classDecl.name,
					base: classDecl.base,
					interfaces: classDecl.interfaces,
					fields: [
						for (field in classDecl.fields)
							if (!field.isStatic) {name: field.name, type: lowerType(field.type)}
					],
					methods: [
						for (method in classDecl.methods)
							if (!method.isStatic && !method.isConstructor) {
								name: method.name.substr(method.name.lastIndexOf(".") + 1),
								functionName: method.name
							}
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

	public static function assemble(functions:Array<IrFunction>, ?natives:Array<IrNative>, ?objects:Array<IrObject>, ?interfaces:Array<IrInterface>):IrProgram {
		var program = new IrProgram("__entry");
		var needsArrayRuntime = false, needsStringRuntime = false;
		for (fn in functions)
			for (block in fn.blocks)
				for (instruction in block.instructions)
					switch instruction {
						case Call(_, name, _):
							if (StringTools.startsWith(name, "__array_alloc_"))
								needsArrayRuntime = true;
							if (name == "__string_concat" || name == "__string_length" || name == "__string_equal" || name == "__string_index_of"
								|| name == "__string_substring")
								needsStringRuntime = true;
						default:
					}
		program.objects = objects == null ? [] : objects;
		program.interfaces = interfaces == null ? [] : interfaces;
		program.natives.push({
			name: "__exit",
			library: "std",
			symbol: "sys_exit",
			arguments: [I32],
			result: Void
		});
		if (needsArrayRuntime) {
			program.natives.push({
				name: "__array_alloc_i32",
				library: "realtime_runtime",
				symbol: "__array_alloc_i32",
				arguments: [I32],
				result: Array(I32)
			});
			program.natives.push({
				name: "__array_alloc_f64",
				library: "realtime_runtime",
				symbol: "__array_alloc_f64",
				arguments: [I32],
				result: Array(F64)
			});
			program.natives.push({
				name: "__array_alloc_bytes",
				library: "realtime_runtime",
				symbol: "__array_alloc_bytes",
				arguments: [I32],
				result: Array(Bytes)
			});
			program.natives.push({
				name: "__array_alloc_bool",
				library: "realtime_runtime",
				symbol: "__array_alloc_bool",
				arguments: [I32],
				result: Array(Bool)
			});
		}
		if (needsStringRuntime)
			program.natives.push({
				name: "__string_concat",
				library: "realtime_runtime",
				symbol: "__string_concat",
				arguments: [Bytes, Bytes],
				result: Bytes
			});
		if (needsStringRuntime)
			program.natives.push({
				name: "__string_length",
				library: "realtime_runtime",
				symbol: "__string_length",
				arguments: [Bytes],
				result: I32
			});
		if (needsStringRuntime)
			program.natives.push({
				name: "__string_equal",
				library: "realtime_runtime",
				symbol: "__string_equal",
				arguments: [Bytes, Bytes],
				result: Bool
			});
		if (needsStringRuntime)
			program.natives.push({
				name: "__string_index_of",
				library: "realtime_runtime",
				symbol: "__string_index_of",
				arguments: [Bytes, Bytes],
				result: I32
			});
		if (needsStringRuntime)
			program.natives.push({
				name: "__string_substring",
				library: "realtime_runtime",
				symbol: "__string_substring",
				arguments: [Bytes, I32, I32],
				result: Bytes
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
				case TIndexAssign(array, index, value, _):
					builder.arraySet(lowerExpression(array, builder, localTypes), lowerExpression(index, builder, localTypes),
						lowerExpression(value, builder, localTypes));
				case TReturn(expression, _):
					builder.returnValue(lowerExpression(expression, builder, localTypes));
				case TReturnVoid(_):
					builder.returnVoid();
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
			case TBoolLiteral(value): builder.constBool(value);
			case TLocal(name):
				var type = localTypes.get(name);
				if (type == null)
					throw 'Missing typed local "$name"';
				builder.load(name, type);
			case TCaptured(name):
				var owner = localTypes.get("this");
				if (owner == null)
					throw 'Captured value "$name" has no environment';
				builder.fieldGet(builder.load("this", owner), name, lowerType(expression.type));
			case TFunctionRef(name): builder.staticClosure(name, lowerType(expression.type));
			case TLambda(name, environment, captures):
				if (environment == null) builder.staticClosure(name, lowerType(expression.type)); else {
					var object = builder.newObject(environment);
					for (capture in captures)
						builder.fieldSet(object, capture, builder.load(capture, localTypes.get(capture)));
					builder.instanceClosure(name, object, lowerType(expression.type));
				}
			case TAdd(a, b):
				var left = lowerExpression(a, builder, localTypes),
					right = lowerExpression(b, builder, localTypes);
				lowerType(expression.type) == Bytes ? builder.call("__string_concat", [left, right], Bytes) : builder.add(left, right);
			case TSub(a, b): builder.sub(lowerExpression(a, builder, localTypes), lowerExpression(b, builder, localTypes));
			case TMul(a, b): builder.mul(lowerExpression(a, builder, localTypes), lowerExpression(b, builder, localTypes));
			case TDiv(a, b): builder.div(lowerExpression(a, builder, localTypes), lowerExpression(b, builder, localTypes));
			case TLess(a, b): builder.less(lowerExpression(a, builder, localTypes), lowerExpression(b, builder, localTypes));
			case TLessEqual(a, b): builder.lessEqual(lowerExpression(a, builder, localTypes), lowerExpression(b, builder, localTypes));
			case TEqual(a, b):
				var left = lowerExpression(a, builder, localTypes),
					right = lowerExpression(b, builder, localTypes);
				lowerType(a.type) == Bytes ? builder.call("__string_equal", [left, right], Bool) : builder.equal(left, right);
			case TCall(name, args): builder.call(name, [for (arg in args) lowerExpression(arg, builder, localTypes)], lowerType(expression.type));
			case TClosureCall(callee, args):
				builder.callClosure(lowerExpression(callee, builder, localTypes), [for (arg in args) lowerExpression(arg, builder, localTypes)],
					lowerType(expression.type));
			case TToInterface(value, name):
				builder.toVirtual(lowerExpression(value, builder, localTypes), Virtual(name));
			case TNew(typeName, args, hasConstructor):
				var object = builder.newObject(typeName);
				if (hasConstructor) {
					var constructorArgs = [object];
					for (arg in args)
						constructorArgs.push(lowerExpression(arg, builder, localTypes));
					builder.call('$typeName.new', constructorArgs, Void);
				}
				object;
			case TNewArray(element, length):
				builder.call(arrayAllocatorName(element), [lowerExpression(length, builder, localTypes)], Array(lowerType(element)));
			case TField(object, name): builder.fieldGet(lowerExpression(object, builder, localTypes), name, lowerType(expression.type));
			case TMethodCall(object, name, args):
				var receiver = lowerExpression(object, builder, localTypes),
					callArgs = [for (arg in args) lowerExpression(arg, builder, localTypes)];
				builder.methodCall(receiver, name.substr(name.lastIndexOf(".") + 1), callArgs, lowerType(expression.type));
			case TIndex(array, index):
				builder.arrayGet(lowerExpression(array, builder, localTypes), lowerExpression(index, builder, localTypes), lowerType(expression.type));
			case TArrayLength(array):
				builder.arraySize(lowerExpression(array, builder, localTypes));
			case TStringLength(value):
				builder.call("__string_length", [lowerExpression(value, builder, localTypes)], I32);
			case TStringIndexOf(value, needle):
				builder.call("__string_index_of", [
					lowerExpression(value, builder, localTypes),
					lowerExpression(needle, builder, localTypes)
				], I32);
			case TStringSubstring(value, start, end):
				builder.call("__string_substring", [
					lowerExpression(value, builder, localTypes),
					lowerExpression(start, builder, localTypes),
					lowerExpression(end, builder, localTypes)
				], Bytes);
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
			case TInterface(name): Virtual(name);
			case TArray(element): Array(lowerType(element));
			case TFunction(arguments, result): Function([for (argument in arguments) lowerType(argument)], lowerType(result));
		};

	static function arrayAllocatorName(element:CompilerType):String
		return switch element {
			case TInt: "__array_alloc_i32";
			case TFloat: "__array_alloc_f64";
			case TString: "__array_alloc_bytes";
			case TBool: "__array_alloc_bool";
			default: throw "Compiler-owned allocation currently supports Int, Float, Bool, and String arrays";
		};
}
