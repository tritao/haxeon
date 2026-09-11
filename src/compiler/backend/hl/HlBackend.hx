package compiler.backend.hl;

import compiler.backend.Backend;
import compiler.backend.Backend.BackendOptions;
import compiler.backend.Backend.BackendResult;
import compiler.backend.Backend.BackendTarget;
import compiler.hl.HlWriter;
import compiler.ir.Ir.IrProgram;
import compiler.ir.hl.HlLower;

/** Stateless HashLink backend adapter behind the same semantic backend seam. */
class HlBackend implements Backend {
	public function new() {}

	public function compile(program:IrProgram, options:BackendOptions):BackendResult {
		if (options.target != HashLink)
			throw 'HashLink backend received target ${options.target}';
		return {target: HashLink, bytes: HlWriter.encode(HlLower.lower(program))};
	}
}
