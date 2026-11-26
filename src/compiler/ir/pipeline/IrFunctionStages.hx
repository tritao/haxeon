package compiler.ir.pipeline;

import compiler.core.InternalError;
import compiler.ir.codec.IrFunctionStateEquality;
import compiler.ir.model.Ir.IrProgram;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrSymbol;
import compiler.ir.reuse.IrFactReader;
import compiler.ir.reuse.IrStageFacts;
import compiler.ir.reuse.IrStageMemo.IrStageMemos;
import compiler.ir.reuse.IrStageMemo.IrStageQueries;

/**
 * The driver of the per-function stages (`IrFunctionPass`), on the session's query database or, in a compile that keeps no
 * session, without it (docs/design/QUERY_ENGINE.md, the stage driver).
 */
class IrFunctionStages {
	/** An assembly stage that runs the pass `make` gives, on the assembly's functions; `done` reads the pass after the run. */
	public static function stage(name:String, make:(IrAssembly, IrPipelineContext) -> IrFunctionPass,
			?done:(IrAssembly, IrFunctionPass) -> Void):compiler.ir.pipeline.IrStage.IrAssemblyStage {
		return new compiler.ir.pipeline.IrStage.IrAssemblyStage(name, function(assembly, context) {
			var pass = make(assembly, context);
			assembly.functions = run(name, pass, assembly.functions, context.stageMemos,
				context.passScratch.bodyBuilder);
			if (done != null)
				done(assembly, pass);
			return assembly;
		}).memoized();
	}

	/**
	 * A stage of the program the target lowers (`IrPipeline.target`) that runs the pass `make` gives, on its functions; `done` reads
	 * the pass after the run and gives the stage's program.
	 */
	public static function programStage(name:String,
			make:(IrProgram, IrPipelineContext) -> IrFunctionPass,
			?done:(IrProgram, IrFunctionPass) -> IrProgram):compiler.ir.pipeline.IrStage {
		return new compiler.ir.pipeline.IrStage(name, function(program, context) {
			var pass = make(program, context);
			program.functions = run(name, pass, program.functions, context.stageMemos, context.passScratch.bodyBuilder);
			return done != null ? done(program, pass) : program;
		});
	}

	/** `pass` on `functions` without a memo: every function is summarized and rewritten. */
	public static function apply(name:String, pass:IrFunctionPass, functions:Array<IrFunction>):Array<IrFunction>
		return run(name, pass, functions, null);

	/**
	 * `pass` on `functions`. With `memos`, each function is a key of the stage's kind (`IrStageQueries`), by its name's number
	 * (`IrSymbol.functionKey`):
	 * one whose memo was made from the same function object and whose facts are unchanged is not read, and its memo's summary,
	 * output and helper requests are this build's; one made again the same is the memo's object (early cutoff), before the encode
	 * point. Past it (`IrStageMemos.bodies`) what a stage makes is frozen, as the stages after it edit copies, and never compared. With
	 * `--check-reuse` (`IrStageMemos.checks`) each reused memo is computed again and compared. A stage that runs once per part of
	 * the program (an element type) names the `part`: its runs share the stage's kind, each with keys of its own.
	 */
	public static function run(name:String, pass:IrFunctionPass, functions:Array<IrFunction>,
			memos:Null<IrStageMemos>, ?builder:compiler.ir.model.IrBodyBuilder, ?part:String):Array<IrFunction> {
		var count = functions.length, summaries:Array<Int> = [];
		summaries.resize(count);
		if (memos == null) {
			var facts = new IrStageFacts();
			facts.run(null, partName(name, part), pass);
			for (index in 0...count)
				summaries[index] = pass.summarize(functions[index]);
			pass.prepare(functions, summaries, new IrFunctionIndex(name, functions));
			var reader = new IrFactReader(pass, facts, null);
			return pass.finish([for (index in 0...count) {
				reader.begin(false);
				pass.transform(functions[index], summaries[index], reader);
			}]);
		}
		var database = memos.database,
			bodies = memos.bodies,
			stage = memos.stage(name, bodies),
			kind = stage.functions,
			checks = memos.checks,
			partKeys = part == null ? null : stage.part(part),
			keys:Array<Int> = [];
		memos.stageFacts.run(database, partName(name, part), pass);
		keys.resize(count);
		for (index in 0...count) {
			var fn = functions[index],
				key = partKeys == null ? fn.symbol.functionKey() : stage.partKey(partKeys,
					fn.symbol.functionKey());
			keys[index] = key;
			summaries[index] = stage.summary(key, fn, pass, checks, name);
		}
		pass.prepare(functions, summaries, new IrFunctionIndex(name, functions));
		var reader = new IrFactReader(pass, memos.stageFacts, database),
			output:Array<IrFunction> = [],
			since = IrFunction.versionsGiven();
		output.resize(count);
		for (index in 0...count) {
			var fn = functions[index], key = keys[index], same = stage.madeFrom(key, fn.version);
			if (same && kind.current(database, key)) {
				output[index] = kind.value(key);
				stage.replay(key, pass);
				if (checks)
					check(name, pass, reader, stage, key, fn, summaries[index], database);
				continue;
			}
			kind.begin(database, key);
			reader.begin(false);
			var made = pass.transform(fn, summaries[index], reader);
			if (made != fn && bodies && made.body != null)
				made.freezeBody(builder);
			// Only what the stage makes again of the same input is compared with what it made before: of another input it is all
			// but never the same.
			output[index] = same ? kind.end(database, key, made) : kind.endChanged(database, key, made);
			stage.made(key, fn.version, summaries[index], reader.requests());
		}
		var result = pass.finish(output);
		// What `finish` added before the encode point (the helpers the rewrites asked for) is last build's when made the same. What
		// the rewrites made is told apart by identity, not by place: `finish` may drop functions, which moves the rest.
		if (!bodies) {
			var added:Null<IrStageQueries> = null;
			for (index in 0...result.length) {
				var fn = result[index];
				if (fn.version > since && (index >= count || output[index] != fn) && !stage.keeps(partKeys, fn)) {
					if (added == null)
						added = memos.stage(ADDED, false);
					result[index] = added.functions.put(database, added.partKey(added.part(partName(name, part)),
						fn.symbol.functionKey()), fn);
				}
			}
		}
		return result;
	}

	/**
	 * The kinds of the functions the stages derive (`derived`), before the encode point and past it, and of those their `finish`
	 * adds: one each, every stage a part of it, as a stage derives or adds a few functions where it rewrites them all.
	 */
	static inline final DERIVED = "ir-derived";

	static inline final DERIVED_BODIES = "ir-derived-bodies";
	static inline final ADDED = "ir-added";

	/** The input of a function `derived` makes from nothing but its name, such as a helper its name describes. */
	public static inline final FROM_NAME = IrStageQueries.FROM_NAME;

	/**
	 * A function `stage` makes besides the functions' own forms, named `name`: a specialization or a rewrite of the function of
	 * version `input` (`IrFunction.version`; `make` returns that function to keep it), or a helper made from its name alone
	 * (`FROM_NAME`). With `memos`, last build's when it was made from the same input and the facts it read are unchanged (its requests are asked for again); else `make` makes it with
	 * a reader that records what it reads and asks for, of the facts of `pass`'s run (`IrStageFacts.run`, which the caller starts),
	 * and past the encode point (`IrStageMemos.bodies`) it is encoded and frozen. Call it while the stage runs, after `prepare`; `part` as `run`'s.
	 */
	public static function derived(stage:String, name:String, pass:IrFunctionPass, input:Int,
			memos:Null<IrStageMemos>, builder:Null<compiler.ir.model.IrBodyBuilder>,
			make:IrFactReader->IrFunction, ?part:String):IrFunction {
		if (memos == null) {
			var reader = new IrFactReader(pass, null, null);
			reader.begin(false);
			return make(reader);
		}
		var database = memos.database,
			bodies = memos.bodies,
			queries = memos.stage(bodies ? DERIVED_BODIES : DERIVED, bodies),
			kind = queries.functions,
			reader = new IrFactReader(pass, memos.stageFacts, database),
			key = queries.partKey(queries.part(partName(stage, part)), IrSymbol.of(name).functionKey());
		var same = queries.madeFrom(key, input);
		if (same && kind.current(database, key)) {
			var kept = kind.value(key);
			queries.replay(key, pass);
			if (memos.checks) {
				kind.begin(database, key);
				reader.begin(true);
				var now = make(reader);
				kind.cancel(database, key);
				if (!IrFunctionStateEquality.same(now, kept)
					|| !IrFunctionPass.IrStageRequest.same(reader.requests(), queries.asked(key)))
					throw new InternalError('--check-reuse: stage $stage reused $name, which differs from what it makes now');
			}
			return kept;
		}
		kind.begin(database, key);
		reader.begin(false);
		var made = make(reader);
		// What the memo keeps is frozen, so the stages after this one edit copies.
		if (bodies && made.version != input) {
			made.encodedBody(builder);
			made.freezeBody(builder);
		}
		var kept = same ? kind.end(database, key, made) : kind.endChanged(database, key, made);
		queries.made(key, input, 0, reader.requests());
		return kept;
	}

	/** The name of `stage`'s run on `part`, when it runs per part. */
	static inline function partName(stage:String, part:Null<String>):String
		return part == null ? stage : stage + ":" + part;

	/** `--check-reuse`: the memo of `key`, reused for `fn`, is what the stage makes of it now. */
	static function check(name:String, pass:IrFunctionPass, reader:IrFactReader, stage:IrStageQueries, key:Int,
			fn:IrFunction, summary:Int, database:compiler.query.QueryDatabase):Void {
		var kind = stage.functions;
		kind.begin(database, key);
		reader.begin(true);
		var made = pass.transform(fn, summary, reader);
		kind.cancel(database, key);
		if (!IrFunctionStateEquality.same(made, kind.value(key)))
			throw new InternalError('--check-reuse: stage $name reused what it made of ${fn.name}, which differs from what it makes now');
		if (!IrFunctionPass.IrStageRequest.same(reader.requests(), stage.asked(key)))
			throw new InternalError('--check-reuse: stage $name reused the helper requests of ${fn.name}, which differ from what it asks for now');
	}
}
