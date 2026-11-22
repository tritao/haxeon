package compiler.hl;

import compiler.backend.Backend;
import compiler.backend.Backend.BackendOptions;
import compiler.backend.Backend.BackendResult;
import compiler.backend.Backend.BackendTarget;
import compiler.core.InternalError;
import compiler.hl.HlWriter;
import compiler.hl.incremental.HlPlainBuild;
import compiler.ir.model.Ir.IrProgram;

/**
 * The HashLink backend behind the stateless `Backend` seam. It assembles the way a plain build of a compilation session does
 * (`HlPlainBuild`: reachable from the entry, a fresh `HlModuleAssembler`), so what it returns is what the compiler ships for the
 * program; only the source snapshots a session attaches from its modules are missing, as there are none.
 */
class HlBackend implements Backend {
	public function new() {}

	public function compile(program:IrProgram, options:BackendOptions):BackendResult {
		if (options.target != HashLink)
			throw new InternalError('HashLink backend received target ${options.target}');
		// A standalone backend can receive semantic IR, without the frontend's lowering of array allocation.
		program = compiler.ir.passes.arrays.IrArrayFactory.physical(program);
		var assembly = HlPlainBuild.assemble(program, options.developmentMetadata != false);
		return {
			target: HashLink,
			bytes: HlWriter.encode(assembly.module).flatten(),
			functionIndices: assembly.functionIndices
		};
	}
}
