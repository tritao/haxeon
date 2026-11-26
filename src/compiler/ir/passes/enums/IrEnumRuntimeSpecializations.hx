package compiler.ir.passes.enums;

import compiler.ir.model.IrFunction;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrOperands;
import compiler.ir.model.IrTypeIds;

import compiler.core.InternalError;
import compiler.ir.model.Ir;
import compiler.types.typing.EnumRuntimeType;

/** Select concrete runtime descriptors from current and cached IR, never from an erased template. */
@:nullSafety(Strict)
class IrEnumRuntimeSpecializations {
	@:processWide("a shared empty list of enum names, only ever read")
	static final NONE:Array<String> = [];

	/** The specialized enum `type` names (one whose declaration is another), each added to `names` once. */
	static function mentions(type:IrType, names:Array<String>):Void
		switch type {
			case Enum(name), EnumTag(name):
				if (EnumRuntimeType.declaration(name) != name && names.indexOf(name) < 0)
					names.push(name);
			case Array(element), Iterator(element), Nullable(element):
				mentions(element, names);
			case Function(arguments, result):
				for (argument in arguments)
					mentions(argument, names);
				mentions(result, names);
			default:
		}

	/**
	 * The specialized enums `functions` name in their signatures, values and type values: in a session, a summary of what each
	 * names at `site` (`IrContributionSummary`), read again only of a function that changed; else read now.
	 */
	static function mentionsOf(functions:Array<IrFunction>, site:String,
			stageMemos:Null<compiler.ir.reuse.IrStageMemo.IrStageMemos>):Array<String> {
		if (stageMemos == null) {
			var shared:Array<Bool> = [];
			return [for (fn in functions) for (name in readMentions(fn, shared)) name];
		}
		var summary:compiler.ir.reuse.IrStageMemo.IrContributionSummary<String> =
			stageMemos.summary("enum-mentions:" + site);
		return summary.collect(stageMemos.database, functions, fn -> readMentions(fn, null), name -> name,
			stageMemos.checks,
			"enum specializations");
	}

	/**
	 * What `fn` names (`mentionsOf`), in the order it names them. A function past the encode point is read as its body, each type once; one before it, as its objects. With
	 * `shared`, by type id, a type an earlier body visited is not visited again: what is read is then only what that union
	 * lacks, for a caller that keeps no contribution.
	 */
	static function readMentions(fn:IrFunction, shared:Null<Array<Bool>>):Array<String> {
		var names:Array<String> = [], body = fn.body;
		if (body != null) {
			var visited:Array<Bool> = shared ?? [];
			inline function visitId(id:Int):Void {
				while (visited.length <= id)
					visited.push(false);
				if (!visited[id]) {
					visited[id] = true;
					mentions(IrTypeIds.type(id), names);
				}
			}
			for (index in 0...body.argumentCount())
				visitId(body.valueTypeId(body.argument(index)));
			visitId(body.result);
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0) {
					var output = body.output(row);
					if (output.exists())
						visitId(body.valueTypeId(output));
					if (body.opcode(row) == IrOpcode.TypeValue)
						visitId(body.aux(row));
					row = body.nextRow(row);
				}
			}
		} else {
			for (argument in fn.arguments)
				mentions(argument.type, names);
			mentions(fn.result, names);
			for (block in fn.blocks)
				for (located in block.instructions) {
					var instruction = located.value, output = IrOperands.output(instruction);
					if (output != null)
						mentions(output.type, names);
					for (inputIndex in 0...IrOperands.count(instruction))
						mentions(IrOperands.at(instruction, inputIndex).type, names);
					switch instruction {
						case TypeValue(_, type): mentions(type, names);
						default:
					}
				}
		}
		return names.length == 0 ? NONE : names;
	}

	public static function materialize(enums:Array<IrEnum>, functions:Array<IrFunction>, objects:Array<IrObject>,
			staticFields:Array<IrStaticField>, natives:Array<IrNative>, interfaces:Array<IrInterface>,
			cNatives:Array<IrCNative>, site:String,
			?stageMemos:compiler.ir.reuse.IrStageMemo.IrStageMemos):Array<IrEnum> {
		var declarations:Map<String, IrEnum> = [for (item in enums) item.name => item],
			required:Map<String, Bool> = [],
			pending:Array<String> = [];
		function require(name:String):Void
			if (!required.exists(name)) {
				required.set(name, true);
				pending.push(name);
			}
		function visit(type:IrType):Void switch type {
			case Enum(name), EnumTag(name):
				if (EnumRuntimeType.declaration(name) != name)
					require(name);
			case Array(element), Iterator(element), Nullable(element): visit(element);
			case Function(arguments, result): for (argument in arguments) visit(argument);
				visit(result);
			default:
		}
		for (name in mentionsOf(functions, site, stageMemos))
			require(name);
		for (declaration in enums) if (EnumRuntimeType.declaration(declaration.name) == declaration.name)
			for (constructor in declaration.cases) for (parameter in constructor.params) visit(parameter);
		for (object in objects) for (field in object.fields) visit(field.type);
		for (contract in interfaces) for (method in contract.methods) {
			for (argument in method.arguments) visit(argument);
			visit(method.result);
		}
		for (field in staticFields) visit(field.type);
		for (native in natives) {
			for (argument in native.arguments) visit(argument);
			visit(native.result);
		}
		for (native in cNatives) {
			for (argument in native.arguments) visit(argument);
			visit(native.result);
		}
		var index = 0;
		while (index < pending.length) {
			var name = pending[index++], declaration = declarations.get(name);
			if (declaration == null) throw new InternalError('Missing concrete enum declaration "$name"');
			for (constructor in declaration.cases) for (parameter in constructor.params) visit(parameter);
		}
		return [for (declaration in enums) if (EnumRuntimeType.declaration(declaration.name) == declaration.name
			|| required.exists(declaration.name)) declaration];
	}
}
