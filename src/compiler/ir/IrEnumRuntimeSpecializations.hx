package compiler.ir;

import compiler.core.InternalError;
import compiler.ir.Ir;
import compiler.types.typing.EnumRuntimeType;

/** Select concrete runtime descriptors from current and cached IR, never from an erased template. */
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
	 * The specialized enums `fn` names in its signature, values and type values, in the order it names them: kept by the session for
	 * `fn`'s version with `lineage` (`IrStageMemos.enumMentions`), else read now.
	 */
	static function mentionsOf(fn:IrFunction, lineage:Null<compiler.ir.IrStageMemo.IrLineage>,
			shared:IrMentionScratch):Array<String> {
		var version = lineage == null ? 0 : lineage.versionOf(fn);
		if (lineage == null || version == 0)
			return readMentions(fn, shared);
		var memo = lineage.memos.enumMentions, known = memo.get(version);
		if (known == null) {
			known = readMentions(fn, null);
			memo.keep(version, known);
		} else if (lineage.checks && readMentions(fn, null).join(",") != known.join(","))
			throw new InternalError('--check-reuse: the enum specializations reused for ${fn.name} differ from its code');
		return known;
	}

	/**
	 * Reads `mentionsOf`. A function past the encode point is read as its body, each type once; one before it, as its objects. With
	 * `shared`, a type an earlier body with the same table visited is not visited again: what is read is then only what that union
	 * lacks, for a caller that keeps no contribution.
	 */
	static function readMentions(fn:IrFunction, shared:Null<IrMentionScratch>):Array<String> {
		var names:Array<String> = [], body = fn.body;
		if (body != null) {
			var visited:Array<Bool> = [];
			if (shared != null) {
				if (shared.types != body.types) {
					shared.types = body.types;
					shared.visited.resize(0);
				}
				visited = shared.visited;
			}
			inline function visitId(id:Int):Void {
				while (visited.length <= id)
					visited.push(false);
				if (!visited[id]) {
					visited[id] = true;
					mentions(body.types.type(id), names);
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
			cNatives:Array<IrCNative>, ?lineage:compiler.ir.IrStageMemo.IrLineage):Array<IrEnum> {
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
		var shared = new IrMentionScratch();
		for (fn in functions)
			for (name in mentionsOf(fn, lineage, shared))
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

/** The types a run of `IrEnumRuntimeSpecializations.materialize` without a memo has visited, by id of one table. */
private class IrMentionScratch {
	public var types:Null<IrTypeIds> = null;
	public final visited:Array<Bool> = [];

	public function new() {}
}
