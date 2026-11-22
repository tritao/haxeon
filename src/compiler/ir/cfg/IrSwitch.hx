package compiler.ir.cfg;

/** The blocks a dense switch (`IrTerminator.Switch`, `CfgTerminator.Switch`) can transfer to. */
class IrSwitch {
	/** Each block `targets` or `otherwise` names, once, in first-mention order: a block several values select is one edge. */
	public static function successors(targets:Array<Int>, otherwise:Int):Array<Int> {
		var result:Array<Int> = [];
		for (target in targets)
			if (result.indexOf(target) < 0)
				result.push(target);
		if (result.indexOf(otherwise) < 0)
			result.push(otherwise);
		return result;
	}

	/** `targets` with every block renamed by `rename`. */
	public static function mapTargets(targets:Array<Int>, rename:Int->Int):Array<Int>
		return [for (target in targets) rename(target)];
}
