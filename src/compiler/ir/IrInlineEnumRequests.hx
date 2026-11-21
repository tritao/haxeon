package compiler.ir;

import compiler.core.InternalError;
import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

/** Resolve typed inline-enum requests through declared providers at an escape boundary. */
class IrInlineEnumRequests {
	public static function resolve(program:IrProgram, functions:Array<IrFunction>):Array<IrFunction> {
		var providers = new IrInlineEnumProviders(program),
			replacements:Null<Map<String, IrFunction>> = null;
		var result:Null<Array<IrFunction>> = null;
		for (functionIndex in 0...functions.length) {
			var fn = functions[functionIndex],
				blocks:Null<Array<IrBlock>> = null;
			for (blockIndex in 0...fn.blocks.length) {
				var block = fn.blocks[blockIndex],
					instructions:Null<Array<Located<IrInstruction>>> = null;
				for (index in 0...block.instructions.length) {
					var located = block.instructions[index],
						replacement:Null<IrInstruction> = switch located.value {
							case Intrinsic(output, InlineEnumBox(type), arguments):
								Call(output, IrSymbol.of(providers.provider(true, type, arguments.length,
									arguments.length == 1 ? arguments[0].type : null, output.type)), arguments);
							case Intrinsic(output, InlineEnumUnbox(type), arguments):
								Call(output, IrSymbol.of(providers.provider(false, type, arguments.length,
									arguments.length == 1 ? arguments[0].type : null, output.type)), arguments);
							default:
								null;
						};
					if (replacement != null) {
						if (instructions == null)
							instructions = block.instructions.slice(0, index);
						instructions.push(new Located(replacement, located.provenance));
					} else if (instructions != null)
						instructions.push(located);
				}
				if (instructions != null) {
					if (blocks == null)
						blocks = fn.blocks.slice(0, blockIndex);
					var rewritten = new IrBlock(block.id);
					for (instruction in instructions)
						rewritten.instructions.push(instruction);
					rewritten.terminator = block.terminator;
					blocks.push(rewritten);
				} else if (blocks != null)
					blocks.push(block);
			}
			if (blocks == null) {
				if (result != null)
					result.push(fn);
			} else {
				if (result == null)
					result = functions.slice(0, functionIndex);
				var replacement = fn.withBlocks(blocks);
				if (replacements == null)
					replacements = [];
				replacements.set(fn.name, replacement);
				result.push(replacement);
			}
		}
		if (replacements != null)
			program.functions = [
				for (fn in program.functions)
					replacements.exists(fn.name) ? replacements.get(fn.name) : fn
			];
		return result == null ? functions : result;
	}
}

/** The provider an inline-enum request resolves to, checked against the enum's declared storage and the provider's signature. */
class IrInlineEnumProviders {
	final program:IrProgram;
	var rows:Null<Map<String, String>> = null;
	var functions:Null<Map<String, IrFunction>> = null;
	var declarations:Null<Map<String, IrEnum>> = null;

	public function new(program:IrProgram)
		this.program = program;

	/**
	 * The name of the function that serves an inline-enum box (`box`) or unbox of `type`, for a request with `count` arguments,
	 * the first of type `argument` (null when there is not one), and output `output`.
	 */
	public function provider(box:Bool, type:IrType, count:Int, argument:Null<IrType>, output:IrType):String {
		var request = IrProviders.typedOperation(box ? InlineEnumBox(type) : InlineEnumUnbox(type));
		if (request == null)
			throw new InternalError("Inline enum operation has no provider request");
		var subject = switch type {
			case Enum(name):
				name;
			default:
				throw new InternalError("Inline enum request requires a nominal enum type");
		};
		var known = declarations;
		if (known == null) {
			known = [for (entry in program.enums) entry.name => entry];
			declarations = known;
		}
		var declaration = known.get(subject);
		if (declaration == null || declaration.inlineStorage == null)
			throw new InternalError("Inline enum request requires declared inline storage");
		var storage:IrType = Obj(declaration.inlineStorage);
		if (count != 1 || argument == null)
			throw new InternalError("Inline enum request requires one argument");
		if (box) {
			if (!IrVerifier.sameType(argument, storage) || !IrVerifier.sameType(output, Dyn))
				throw new InternalError("Invalid inline enum box request signature");
		} else if (!IrVerifier.sameType(argument, Dyn) || !IrVerifier.sameType(output, storage))
			throw new InternalError("Invalid inline enum unbox request signature");
		var table = rows;
		if (table == null) {
			table = IrProviders.rows(program.functions);
			rows = table;
		}
		var name = table.get(IrProviders.row(request.subject, request.operation));
		if (name == null)
			throw new InternalError('Missing inline enum provider for ${request.subject} / ${request.operation}');
		var byName = functions;
		if (byName == null) {
			byName = [for (fn in program.functions) fn.name => fn];
			functions = byName;
		}
		var provider = byName.get(name);
		if (provider == null
			|| provider.arguments.length != 1
			|| !IrVerifier.sameType(argument, provider.arguments[0].type)
			|| !IrVerifier.sameType(output, provider.result))
			throw new InternalError('Invalid inline enum provider signature for $name');
		return name;
	}
}
