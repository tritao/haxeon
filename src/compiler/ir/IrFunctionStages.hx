package compiler.ir;

import compiler.core.InternalError;
import compiler.ir.IrStageMemo.IrLineage;
import compiler.ir.IrStageMemo.IrStageEntry;

/** The driver of the per-function stages (`IrFunctionPass`), with or without their session memo. */
class IrFunctionStages {
	/** An assembly stage that runs the pass `make` gives, on the assembly's functions; `done` reads the pass after the run. */
	public static function stage(name:String, make:(IrAssembly, IrPipelineContext) -> IrFunctionPass,
			?done:(IrAssembly, IrFunctionPass) -> Void):compiler.ir.IrStage.IrAssemblyStage {
		return new compiler.ir.IrStage.IrAssemblyStage(name, function(assembly, context) {
			var pass = make(assembly, context);
			assembly.functions = run(name, pass, assembly.functions, context.lineage, context.options.checkReuse);
			if (done != null)
				done(assembly, pass);
			return assembly;
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
			lineage:Null<IrLineage>, checks:Bool):Array<IrFunction> {
		if (lineage == null) {
			var summaries = [for (fn in functions) pass.summarize(fn)];
			pass.prepare(functions, summaries);
			var reader = new IrFactReader(name, pass);
			return pass.finish([for (index in 0...functions.length) {
				reader.begin(false);
				pass.transform(functions[index], summaries[index], reader);
			}]);
		}
		var memos = lineage.memos, memo = memos.stage(name), facts = memos.facts;
		facts.begin();
		var count = functions.length,
			entries:Array<Null<IrStageEntry>> = [],
			summaries:Array<Int> = [];
		for (fn in functions) {
			var version = lineage.version(fn.name), entry = memo.last(fn.name);
			if (entry != null && (version == 0 || entry.input != version))
				entry = null;
			entries.push(entry);
			summaries.push(entry != null ? entry.summary : pass.summarize(fn));
		}
		pass.prepare(functions, summaries);
		var reader = new IrFactReader(name, pass, facts), output:Array<IrFunction> = [];
		for (index in 0...count) {
			var fn = functions[index], entry = entries[index];
			if (entry != null && facts.hold(entry.facts, pass)) {
				var requests = entry.requests;
				if (requests != null)
					for (type in requests)
						pass.request(type);
				if (checks)
					check(name, pass, reader, fn, entry);
			} else {
				reader.begin(false);
				var input = lineage.version(fn.name),
					made = pass.transform(fn, summaries[index], reader),
					last = memo.last(fn.name),
					version = input;
				if (made != fn) {
					if (last != null && input != 0 && last.input == input
						&& compiler.ir.codec.IrFunctionStateEquality.same(last.output, made)) {
						made = last.output;
						version = last.outputVersion;
					} else
						version = memos.versions.next();
				}
				entry = new IrStageEntry(input, reader.recorded(), made, version, summaries[index], reader.requests());
			}
			memo.keep(fn.name, entry);
			lineage.set(entry.output, entry.outputVersion);
			output.push(entry.output);
		}
		var result = pass.finish(output);
		lineage.settle(name, result);
		return result;
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
		var now = reader.requests(), reused = entry.requests;
		var nowCount = now == null ? 0 : now.length, reusedCount = reused == null ? 0 : reused.length;
		var same = nowCount == reusedCount;
		if (same && now != null && reused != null)
			for (index in 0...nowCount)
				if (!IrVerifier.sameType(now[index], reused[index]))
					same = false;
		if (!same)
			throw new InternalError('--check-reuse: stage $name reused the helper requests of ${fn.name}, which differ from what it asks for now');
	}
}
