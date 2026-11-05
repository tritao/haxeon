package compiler.runtime;

import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.IrOperands;
import compiler.ir.IrValueLaneRuntime;

/**
 * Emit the lane policy SSA as native C, without maintaining another implementation of that policy.
 * This deliberately accepts only the instruction subset used by IrValueLaneRuntime; adding a new
 * instruction there requires an explicit, checked native lowering here.
 */
class ValueLaneNativeSource {
	public static function generate(roundSparseCapacity:Bool = true):String {
		var functions = IrValueLaneRuntime.program(roundSparseCapacity).functions, out = new StringBuf();
		out.add("/* Generated from compiler.ir.IrValueLaneRuntime. Do not edit. */\n");
		for (fn in functions) out.add(signature(fn) + ";\n");
		for (fn in functions) emitFunction(out, fn);
		return out.toString();
	}

	static function name(value:String):String {
		if (StringTools.startsWith(value, IrValueLaneRuntime.PREFIX))
			return "realtime_lane_" + value.substr(IrValueLaneRuntime.PREFIX.length).split("-").join("_");
		if (StringTools.startsWith(value, IrValueLaneRuntime.PRIMITIVE))
			return "realtime_lane_storage_" + value.substr(IrValueLaneRuntime.PRIMITIVE.length).split("-").join("_");
		throw 'Unexpected lane runtime callee: $value';
	}

	static function type(value:IrType):String return switch value {
		case Void: "void";
		case I32: "int32_t";
		case Bool: "bool";
		case Array(Dyn): "varray *";
		case Dyn: "vdynamic *";
		default: throw 'Unexpected lane runtime type: $value';
	};
	static function variable(value:IrValue):String return 'v${value.id}';
	static function declaration(value:IrValue):String return type(value.type) + " " + variable(value);
	static function signature(fn:IrFunction):String
		return 'static ${type(fn.result)} ${name(fn.name)}(' + (fn.arguments.length == 0 ? "void" : [for (arg in fn.arguments) declaration(arg)].join(", ")) + ")";

	static function emitFunction(out:StringBuf, fn:IrFunction):Void {
		out.add("\n" + signature(fn) + " {\n");
		var blocks:Map<Int, IrBlock> = [for (block in fn.blocks) block.id => block];
		for (block in fn.blocks) for (item in block.instructions) {
			var value = IrOperands.output(item.value);
			if (value != null && value.type != Void) {
				out.add("\t" + declaration(value) + ";\n");
				switch item.value { case Phi(_, _): out.add('\t${type(value.type)} p${value.id};\n'); default: }
			}
		}
		function edge(from:Int, target:Int):String {
			var reads:Array<String> = [], writes:Array<String> = [];
			for (item in blocks.get(target).instructions) switch item.value {
				case Phi(value, inputs):
					var input = null;
					for (candidate in inputs) if (candidate.block == from) input = candidate.value;
					if (input == null) throw 'Missing lane runtime phi edge $from -> $target';
					reads.push('p${value.id} = ${variable(input)};');
					writes.push('${variable(value)} = p${value.id};');
				default:
			}
			return reads.concat(writes).concat(['goto block_$target;']).join(" ");
		}
		out.add('\tgoto block_${fn.blocks[0].id};\n');
		for (block in fn.blocks) {
			out.add('block_${block.id}:\n');
			for (item in block.instructions) {
				var value = IrOperands.output(item.value), expression:Null<String> = switch item.value {
					case Phi(_, _) | ConstVoid(_): null;
					case ConstInt(_, number): Std.string(number);
					case ConstBool(_, boolean): boolean ? "true" : "false";
					case ConstNull(_): "NULL";
					case Add(_, a, z): '(int32_t)((uint32_t)${variable(a)} + (uint32_t)${variable(z)})';
					case Sub(_, a, z): '(int32_t)((uint32_t)${variable(a)} - (uint32_t)${variable(z)})';
					case Mul(_, a, z): '(int32_t)((uint32_t)${variable(a)} * (uint32_t)${variable(z)})';
					case Div(_, a, z): '${variable(a)} / ${variable(z)}';
					case Less(_, a, z): '${variable(a)} < ${variable(z)}';
					case LessEqual(_, a, z): '${variable(a)} <= ${variable(z)}';
					case Equal(_, a, z): '${variable(a)} == ${variable(z)}';
					case Call(_, callee, arguments): name(callee) + "(" + [for (arg in arguments) variable(arg)].join(", ") + ")";
					default: throw 'Unsupported lane runtime C instruction: ${item.value}';
				};
				if (expression != null) out.add("\t" + (value.type == Void ? "" : variable(value) + " = ") + expression + ";\n");
			}
			if (block.terminator == null) throw 'Unterminated lane runtime block ${block.id}';
			out.add("\t" + (switch block.terminator.value {
				case Jump(target): edge(block.id, target);
				case Branch(condition, yes, no): 'if (${variable(condition)}) { ${edge(block.id, yes)} } else { ${edge(block.id, no)} }';
				case Return(value): value.type == Void ? "return;" : 'return ${variable(value)};';
				case Throw(value): 'hl_throw(${variable(value)}); abort();';
				default: throw 'Unsupported lane runtime C terminator: ${block.terminator.value}';
			}) + "\n");
		}
		out.add("}\n");
	}
}
