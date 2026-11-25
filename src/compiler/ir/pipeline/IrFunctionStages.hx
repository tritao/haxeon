package compiler.ir.pipeline;

import compiler.core.InternalError;
import compiler.ir.model.Ir.IrProgram;
import compiler.ir.model.IrFunction;
import compiler.ir.reuse.IrFactReader;
import compiler.ir.reuse.IrFacts;
import compiler.ir.reuse.IrStageMemo.IrLineage;
import compiler.ir.reuse.IrStageMemo.IrStageEntry;

/** The driver of the per-function stages (`IrFunctionPass`), with or without their session memo. */
class IrFunctionStages {
	/** An assembly stage that runs the pass `make` gives, on the assembly's functions; `done` reads the pass after the run. */
	public static function stage(name:String, make:(IrAssembly, IrPipelineContext) -> IrFunctionPass,
			?done:(IrAssembly, IrFunctionPass) -> Void):compiler.ir.pipeline.IrStage.IrAssemblyStage {
		return new compiler.ir.pipeline.IrStage.IrAssemblyStage(name, function(assembly, context) {
			var pass = make(assembly, context);
			assembly.functions = run(name, pass, assembly.functions, context.lineage, context.options.checkReuse,
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
			program.functions = run(name, pass, program.functions, context.lineage, context.options.checkReuse,
				context.passScratch.bodyBuilder);
			return done != null ? done(program, pass) : program;
		}).memoized();
	}

	/** `pass` on `functions` without a memo: every function is summarized and rewritten. */
	public static function apply(name:String, pass:IrFunctionPass, functions:Array<IrFunction>):Array<IrFunction>
		return run(name, pass, functions, null, false);

	/**
	 * `pass` on `functions`. With `lineage`, a function whose input version (`IrLineage`) and recorded facts are what the stage's
	 * memo has is not read: the memo's summary, output and requests are this build's. With `checks` (`--check-reuse`) each reused
	 * entry is computed again and compared.
	 */
	public static function run(name:String, pass:IrFunctionPass, functions:Array<IrFunction>,
			lineage:Null<IrLineage>, checks:Bool, ?builder:compiler.ir.model.IrBodyBuilder):Array<IrFunction> {
		if (lineage == null) {
			var summaries = [for (fn in functions) pass.summarize(fn)];
			pass.prepare(functions, summaries, new IrFunctionIndex(name, functions));
			var reader = new IrFactReader(name, pass, IrFacts.unshared());
			return pass.finish([for (index in 0...functions.length) {
				reader.begin(false);
				pass.transform(functions[index], summaries[index], reader);
			}]);
		}
		var memos = lineage.memos, memo = memos.stage(name), facts = memos.facts, slots = lineage.slots;
		facts.begin();
		// Each function's slot, remembered on the function, indexes the lineage and the memo: an unchanged function is not looked
		// up by name. A stage may be given functions that something between it and the last settling made: the lineage takes them
		// first, as they are read, so a name's version is its function's.
		var count = functions.length,
			at:Array<Int> = [],
			entries:Array<Null<IrStageEntry>> = [],
			summaries:Array<Int> = [],
			inputStage = name + ":input",
			mark = lineage.startSettling();
		at.resize(count);
		entries.resize(count);
		summaries.resize(count);
		for (index in 0...count) {
			var given = functions[index],
				slot = slots.of(given),
				fn = lineage.settleEntry(inputStage, slot, given, mark);
			if (fn != given)
				functions[index] = fn;
			var version = lineage.versionAt(slot), entry = memo.last(slot);
			if (entry != null && (version == 0 || entry.input != version))
				entry = null;
			at[index] = slot;
			entries[index] = entry;
			summaries[index] = entry != null ? entry.summary : pass.summarize(fn);
		}
		lineage.endSettling(mark, count);
		pass.prepare(functions, summaries, new IrFunctionIndex(name, functions, lineage));
		var reader = new IrFactReader(name, pass, facts), output:Array<IrFunction> = [];
		output.resize(count);
		for (index in 0...count) {
			var fn = functions[index], slot = at[index], entry = entries[index];
			if (entry != null && facts.hold(entry.facts, pass)) {
				var requests = entry.requests;
				if (requests != null)
					for (request in requests)
						pass.request(request.kind, request.type, request.name);
				if (checks)
					check(name, pass, reader, fn, entry);
			} else {
				reader.begin(false);
				var input = lineage.versionAt(slot),
					made = pass.transform(fn, summaries[index], reader),
					last = memo.last(slot),
					version = input;
				if (made != fn && lineage.bodies) {
					// Past the encode point what a memo keeps is frozen, so the stages after it edit copies; nothing is compared
					// with what the stage made last build.
					var body = made.body;
					if (body != null)
						made.freezeBody(builder);
					version = memos.versions.next();
				} else if (made != fn) {
					if (last != null && input != 0 && last.input == input
						&& compiler.ir.codec.IrFunctionStateEquality.same(last.output, made)) {
						made = last.output;
						version = last.outputVersion;
					} else
						version = memos.versions.next();
				}
				entry = new IrStageEntry(input, reader.recorded(), made, version, summaries[index], reader.requests());
			}
			memo.keep(slot, entry);
			// A function the stage left alone stands for its name already, with its version.
			var out = entry.output;
			if (out != fn)
				lineage.set(out, entry.outputVersion);
			else if (entry.outputVersion != lineage.versionAt(slot))
				lineage.setAt(slot, out, entry.outputVersion);
			entries[index] = entry;
			output[index] = out;
		}
		// What the stage made of each function stands for its name: only what `finish` added or replaced is settled.
		var result = pass.finish(output);
		mark = lineage.startSettling();
		for (index in 0...result.length) {
			var fn = result[index],
				entry = index < count ? entries[index] : null,
				slot = entry != null && entry.output == fn ? at[index] : slots.of(fn),
				settled = lineage.settleEntry(name, slot, fn, mark);
			if (settled != fn)
				result[index] = settled;
		}
		lineage.endSettling(mark, result.length);
		return result;
	}

	/** The input of a function `derived` makes from nothing but its name, such as a helper its name describes. */
	public static inline final FROM_NAME = -1;

	/**
	 * A function `stage` makes in its `finish` besides the functions' own forms, named `name`: a specialization or a rewrite of the
	 * function of version `input` (which keeps that version when `make` returns it), or a helper (`FROM_NAME`). With `lineage`, last build's when it was made from the same input and the facts it
	 * read still hold (its requests are replayed); else `make` makes it with a reader that records what it reads and asks for, in the
	 * stage's own facts, and past the encode point it is encoded and frozen. Call it while the stage runs, after
	 * `prepare`.
	 */
	public static function derived(stage:String, name:String, pass:IrFunctionPass, input:Int, lineage:Null<IrLineage>,
			checks:Bool, builder:Null<compiler.ir.model.IrBodyBuilder>,
			make:IrFactReader->IrFunction):IrFunction {
		if (lineage == null) {
			var reader = new IrFactReader(stage, pass, IrFacts.unshared());
			reader.begin(false);
			return make(reader);
		}
		var memos = lineage.memos,
			memo = memos.stage(stage + IrLineage.DERIVED),
			facts = memos.facts,
			reader = new IrFactReader(stage, pass, facts),
			slot = lineage.slots.named(name),
			entry = memo.last(slot);
		if (entry != null && input != 0 && entry.input == input && facts.hold(entry.facts, pass)) {
			var requests = entry.requests;
			if (requests != null)
				for (request in requests)
					pass.request(request.kind, request.type, request.name);
			if (checks) {
				reader.begin(true);
				var now = make(reader);
				if (!compiler.ir.codec.IrFunctionStateEquality.same(now, entry.output)
					|| !IrFunctionPass.IrStageRequest.same(reader.requests(), entry.requests))
					throw new InternalError('--check-reuse: stage $stage reused $name, which differs from what it makes now');
			}
		} else {
			reader.begin(false);
			var made = make(reader);
			// A function made from its input and left alone keeps the input's version.
			var kept = input > 0 && lineage.versionOf(made) == input;
			// What the memo keeps is frozen, so the stages after this one edit copies.
			if (lineage.bodies && !kept) {
				made.encodedBody(builder);
				made.freezeBody(builder);
			}
			entry = new IrStageEntry(input, reader.recorded(), made, kept ? input : memos.versions.next(), 0,
				reader.requests());
		}
		memo.keep(slot, entry);
		lineage.set(entry.output, entry.outputVersion);
		return entry.output;
	}

	/** `--check-reuse`: `entry`, reused for `fn`, is what the stage makes of it now. */
	static function check(name:String, pass:IrFunctionPass, reader:IrFactReader, fn:IrFunction,
			entry:IrStageEntry):Void {
		var summary = pass.summarize(fn);
		if (summary != entry.summary)
			throw new InternalError('--check-reuse: stage $name reused the summary of ${fn.name} ($summary now, ${entry.summary} reused)');
		reader.begin(true);
		var made = pass.transform(fn, summary, reader);
		if (!compiler.ir.codec.IrFunctionStateEquality.same(made, entry.output))
			throw new InternalError('--check-reuse: stage $name reused what it made of ${fn.name} (${Std.int(entry.facts.length / 2)} facts), which differs from what it makes now');
		var same = IrFunctionPass.IrStageRequest.same(reader.requests(), entry.requests);
		if (!same)
			throw new InternalError('--check-reuse: stage $name reused the helper requests of ${fn.name}, which differ from what it asks for now');
	}
}
