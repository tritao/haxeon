package compiler.ir;

import compiler.ir.Ir.IrBlock;
import compiler.ir.Ir.IrInstruction;
import compiler.ir.Ir.IrTerminator;
import compiler.ir.SourceProvenance.Located;
import compiler.ir.SourceProvenance.SourceLocation;

/**
 * A function the frontend keeps across an edit of its file, because its own text did not change, still names the file as it was when it
 * was typed: every location carries the content hash of that text, and the module's source snapshot is now another text. A debug span
 * with a hash the module has no snapshot for cannot be shown, and the module differs from a fresh build of the same sources.
 *
 * This gives such a function the hashes of the files as they are now. The function's own range is unchanged, or it would have been typed
 * again, so the text the spans point at is the same in the new snapshot. The cached function is not touched: a function with a stale hash
 * comes back as a new one (the same object when nothing is stale), for the caller to store through its normal commit.
 */
class IrSourceRehash {
	/** `hashes` maps a file path to its current content hash; a location whose file is not in it is left as it is. */
	public static function of(fn:IrFunction, hashes:Map<String, Int>):IrFunction {
		// Look first, without allocating: nearly every function of nearly every build is current, and a copy made to find that out costs
		// as much as the function.
		if (!isStale(fn, hashes))
			return fn;
		var changed = false;
		function fix(provenance:SourceProvenance):SourceProvenance {
			var location = provenance.location;
			if (location == null || location.sourceHash == 0)
				return provenance;
			var current = hashes.get(location.path);
			if (current == null || current == location.sourceHash)
				return provenance;
			changed = true;
			return new SourceProvenance(new SourceLocation(location.path, location.start, location.end, location.line, location.column,
				location.endLine, location.endColumn, current), provenance.origin);
		}
		var blocks:Array<IrBlock> = [];
		for (block in fn.blocks) {
			var copy = new IrBlock(block.id);
			for (instruction in block.instructions)
				copy.instructions.push(new Located<IrInstruction>(instruction.value, fix(instruction.provenance)));
			var terminator = block.terminator;
			copy.terminator = terminator == null ? null : new Located<IrTerminator>(terminator.value, fix(terminator.provenance));
			blocks.push(copy);
		}
		return changed ? fn.withBlocks(blocks) : fn;
	}

	static function stale(provenance:SourceProvenance, hashes:Map<String, Int>):Bool {
		var location = provenance.location;
		if (location == null || location.sourceHash == 0)
			return false;
		var current = hashes.get(location.path);
		return current != null && current != location.sourceHash;
	}

	/** Whether any location of `fn` names a file by a hash other than the file's current one. */
	public static function isStale(fn:IrFunction, hashes:Map<String, Int>):Bool {
		for (block in fn.blocks) {
			for (instruction in block.instructions)
				if (stale(instruction.provenance, hashes))
					return true;
			var terminator = block.terminator;
			if (terminator != null && stale(terminator.provenance, hashes))
				return true;
		}
		return false;
	}
}
