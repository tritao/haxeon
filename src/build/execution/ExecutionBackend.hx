package build.execution;

import build.execution.ActionResult.ExecutionResult;

/** Replaceable execution boundary; build semantics stop at ExecutionPlan. */
interface ExecutionBackend {
	function execute(plan:ExecutionPlan):ExecutionResult;
	function name():String;
}

class ExecutionBackendFactory {
	public static function create(environment:build.BuildEnvironment, jobs:Int, ?print:String->Void):ExecutionBackend {
		var requested = Sys.getEnv("HAXEON_EXECUTOR");
		if (requested == null || requested == "" || requested == "native")
			return new Executor(environment, jobs, print);
		throw 'Unknown Haxeon executor backend "$requested"; available backends: native';
	}
}
