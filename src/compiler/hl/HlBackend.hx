package compiler.hl;

import compiler.backend.Backend;
import compiler.backend.Backend.BackendOptions;
import compiler.backend.Backend.BackendResult;
import compiler.backend.Backend.BackendTarget;
import compiler.core.InternalError;
import compiler.hl.incremental.HlPlainBuild;
import compiler.ir.model.Ir.IrProgram;

/**
 * The HashLink backend behind the stateless `Backend` seam. It assembles and writes the way a plain build of a compilation session
 * does (`HlPlainBuild`: reachable from the entry, a fresh `HlModuleAssembler`, module sections), so what it returns is what the
 * compiler ships for the program; only the source snapshots a session attaches from its modules are missing, as there are none.
 * Without modules nothing has a home, so the program is one shared section.
 */
class HlBackend implements Backend {
	public function new() {}

	public function compile(program:IrProgram, options:BackendOptions):BackendResult {
		if (options.target != HashLink)
			throw new InternalError('HashLink backend received target ${options.target}');
		// A standalone backend can receive semantic IR, without the frontend's lowering of array allocation.
		program = compiler.ir.passes.arrays.IrArrayFactory.physical(program);
		var assembly = HlPlainBuild.assemble(program, options.developmentMetadata != false, options.sources),
			written = HlSectionWriter.write(assembly.module, [], new compiler.semantic.DeclarationOwners(), HlLz4.FAST);
		// The loader numbers a module of sections itself.
		var functionIndices:Map<String, Int> = [];
		for (name => index in assembly.functionIndices)
			if (index < written.linkedIndices.length && written.linkedIndices[index] >= 0)
				functionIndices.set(name, written.linkedIndices[index]);
		return {
			target: HashLink,
			bytes: written.bytes.flatten(),
			functionIndices: functionIndices
		};
	}
}
