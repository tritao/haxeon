package compiler.ir.verify;

import compiler.ir.model.Ir;
import compiler.ir.model.IrDeclarationEquality;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrFunction.IrFunctionKind;
import compiler.ir.model.IrTypeIdentity;
import compiler.ir.pipeline.IrFunctionPass;
import compiler.ir.reuse.IrFactReader;
import compiler.ir.verify.IrVerifier.IrVerifyProgram;

/**
 * Verification of the final IR as a per-function stage on the session's database (`IrFunctionStages.run`): the check of a function
 * is a memo whose reads are the facts it read of the program (`IrVerifyProgram`'s tables), so a build verifies again only the
 * functions it made and those that read a table entry whose answer changed. The program-level checks run in full every build
 * (`prepare`). A function's check rewrites nothing: the stage gives each function back.
 *
 * A fact's value is a number that changes when its answer does, compared part by part with the answer it was last worked out from
 * (`IrVerifyAnswers`), never by its text.
 */
class IrVerifyStage extends IrFunctionPass {
	final program:IrProgram;
	final checkBodies:Bool;

	/** The session's answers, or null in a compile that keeps none: its facts are never compared. */
	final answers:Null<IrVerifyAnswers>;

	var checked:Null<IrVerifyProgram> = null;
	var reading = false;

	public function new(program:IrProgram, answers:Null<IrVerifyAnswers>, checkBodies:Bool) {
		this.program = program;
		this.answers = answers;
		this.checkBodies = checkBodies;
	}

	override public function summarize(fn:IrFunction):Int
		return 0;

	override public function prepare(functions:Array<IrFunction>, summaries:Array<Int>,
			names:compiler.ir.pipeline.IrFunctionIndex):Void
		checked = IrVerifier.prepare(program, checkBodies);

	override public function transform(fn:IrFunction, summary:Int, reader:IrFactReader):IrFunction {
		var program = prepared();
		// A compile that keeps no session reads the tables without recording: nothing checks its facts again.
		if (answers != null && !reading) {
			program.readThrough(reader);
			reading = true;
		}
		var enumChecks = program.inlineEnums;
		if (enumChecks != null) {
			if (reading)
				reader.read(IrVerifyProgram.INLINE_ENUMS, "");
			enumChecks.check(fn);
		}
		program.verify(fn);
		return fn;
	}

	override public function finish(functions:Array<IrFunction>):Array<IrFunction>
		return functions;

	override public function fact(kind:Int, key:String):Int
		return 0;

	override public function factOf(id:Int, kind:Int, key:String, known:Bool, last:Int):Int {
		var kept = answers;
		return kept == null ? 0 : kept.settle(id, kind, prepared().answer(kind, key), known, last);
	}

	function prepared():IrVerifyProgram {
		var known = checked;
		if (known == null)
			throw new compiler.core.InternalError("the verifier checks a function before the program");
		return known;
	}
}

/**
 * The answers verification's facts were last worked out from, by fact (`IrStageFacts`), kept by the session (`IrStageMemos.verifier`):
 * a fact keeps its value while its answer is the same part by part, and takes another when it is not.
 */
class IrVerifyAnswers {
	final answers:Array<Dynamic> = [];

	public function new() {}

	/**
	 * The value of fact `id`, of `kind`, whose answer is `now`: `last`, its value, when it is `known` and its answer was the same,
	 * else another.
	 */
	public function settle(id:Int, kind:Int, now:Dynamic, known:Bool, last:Int):Int {
		while (answers.length <= id)
			answers.push(null);
		var before = answers[id];
		answers[id] = now;
		return known && sameAnswer(kind, before, now) ? last : last + 1;
	}

	/** Lets go of every answer, for a compile that keeps no session. */
	public function clear():Void
		answers.resize(0);

	/** Whether two answers of a table read the same to the verifier: its declarations part by part, its flags and names as values. */
	static function sameAnswer(kind:Int, last:Dynamic, now:Dynamic):Bool {
		if (last == null || now == null)
			return last == now;
		return switch kind {
			case IrVerifyProgram.SIGNATURES:
				var before:{arguments:Array<IrType>, result:IrType, kind:IrFunctionKind} = last,
					after:{arguments:Array<IrType>, result:IrType, kind:IrFunctionKind} = now;
				IrDeclarationEquality.sameTypes(before.arguments, after.arguments)
					&& IrTypeIdentity.same(before.result, after.result)
					&& compiler.ir.codec.IrFunctionStateEquality.sameKind(before.kind, after.kind);
			case IrVerifyProgram.OBJECTS: IrDeclarationEquality.sameObject(last, now);
			case IrVerifyProgram.INTERFACES: IrDeclarationEquality.sameInterface(last, now);
			case IrVerifyProgram.ENUMS: IrDeclarationEquality.sameEnum(last, now);
			case IrVerifyProgram.GLOBALS: IrTypeIdentity.same(last, now);
			case _: last == now;
		};
	}
}
