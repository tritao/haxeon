package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

/** Resolve typed inline-enum requests through declared providers at an escape boundary. */
class IrInlineEnumRequests {
	public static function resolve(program:IrProgram, functions:Array<IrFunction>):Array<IrFunction> {
		var rows:Null<Map<String, String>> = null, providers:Null<Map<String, IrFunction>> = null, declarations:Null<Map<
			String,
			IrEnum
		>> = null, replacements:Null<Map<
			String,
			IrFunction
		>> = null;
		function resolveOperation(output:IrValue, operation:IrIntrinsic, arguments:Array<IrValue>):IrInstruction {
			var request = IrProviders.typedOperation(operation);
			if (request == null) throw "Inline enum operation has no provider request";
			var subject = switch operation {
				case InlineEnumBox(Enum(name)), InlineEnumUnbox(Enum(name)):
					name;
				default:
					throw "Inline enum request requires a nominal enum type";
			};
			if (declarations == null) declarations = [for (entry in program.enums) entry.name => entry];
			var declaration = declarations.get(subject);
			if (declaration == null
				|| declaration.inlineStorage == null) throw "Inline enum request requires declared inline storage";
			var storage:IrType = Obj(declaration.inlineStorage);
			if (arguments.length != 1) throw "Inline enum request requires one argument";
			switch operation {
				case InlineEnumBox(_):
					if (!IrVerifier.sameType(arguments[0].type,
						storage) || !IrVerifier.sameType(output.type, Dyn)) throw "Invalid inline enum box request signature";
				case InlineEnumUnbox(_):
					if (!IrVerifier.sameType(arguments[0].type,
						Dyn) || !IrVerifier.sameType(output.type, storage)) throw "Invalid inline enum unbox request signature";
				default:
					throw "Expected an inline enum request";
			}
			if (rows == null) rows = IrProviders.rows(program.functions);
			var name = rows.get(IrProviders.row(request.subject, request.operation));
			if (name == null) throw 'Missing inline enum provider for ${request.subject} / ${request.operation}';
			if (providers == null) providers = [for (fn in program.functions) fn.name => fn];
			var provider = providers.get(name);
			if (provider == null || provider.arguments.length != 1 || !IrVerifier.sameType(
				arguments[0].type,
				provider.arguments[0].type
			) || !IrVerifier.sameType(
				output.type,
				provider.result
			)) throw 'Invalid inline enum provider signature for $name';
			return Call(output, name, arguments);
		}
		var result:Null<Array<IrFunction>> = null;
		for (functionIndex in 0...functions.length) {
			var fn = functions[functionIndex], blocks:Null<Array<IrBlock>> = null;
			for (blockIndex in 0...fn.blocks.length) {
				var block = fn.blocks[blockIndex], instructions:Null<Array<Located<IrInstruction>>> = null;
				for (index in 0...block.instructions.length) {
					var located = block.instructions[index], replacement:Null<IrInstruction> = switch located.value {
						case Intrinsic(output, InlineEnumBox(type), arguments):
							resolveOperation(output, InlineEnumBox(type), arguments);
						case Intrinsic(output, InlineEnumUnbox(type), arguments):
							resolveOperation(output, InlineEnumUnbox(type), arguments);
						default:
							null;
					};
					if (replacement != null) {
						if (instructions == null) instructions = block.instructions.slice(0, index);
						instructions.push(new Located(replacement, located.provenance));
					} else if (instructions != null) instructions.push(located);
				}
				if (instructions != null) {
					if (blocks == null) blocks = fn.blocks.slice(0, blockIndex);
					var rewritten = new IrBlock(block.id);
					for (instruction in instructions) rewritten.instructions.push(instruction);
					rewritten.terminator = block.terminator;
					blocks.push(rewritten);
				} else if (blocks != null) blocks.push(block);
			}
			if (blocks == null) {
				if (result != null) result.push(fn);
			} else {
				if (result == null) result = functions.slice(0, functionIndex);
				var replacement = fn.withBlocks(blocks);
				if (replacements == null) replacements = [];
				replacements.set(fn.name, replacement);
				result.push(replacement);
			}
		}
		if (replacements != null) program.functions = [for (fn in program.functions) replacements.exists(fn.name)
			? replacements.get(fn.name) : fn];
		return result == null ? functions : result;
	}
}
