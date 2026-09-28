package compiler.ffi;

import compiler.ffi.HxiModel.HxiInterface;

/**
 * Orders FFI interface sources so each comes after the interfaces it depends
 * on. The compiler validates an interface against its dependencies when it is
 * registered, but a package lists its interface files in path order, and a
 * dependent's path can sort first (`policy/...` before `runtime/...`).
 */
class HxiInterfaceOrder {
	/**
	 * A stable depth-first ordering: files keep their relative order except that
	 * a dependency is pulled ahead of the first file that needs it. Dependencies
	 * that no listed file provides, and cycles, are left alone for the compiler
	 * to report.
	 */
	public static function dependenciesFirst(sources:Array<{path:String, text:String}>):Array<{path:String, text:String}> {
		var models:Array<HxiInterface> = [for (source in sources) HxiParser.parse(source.path, source.text)];
		var indexByName:Map<String, Int> = [];
		for (index in 0...models.length)
			if (!indexByName.exists(models[index].name))
				indexByName.set(models[index].name, index);
		var state:Array<Int> = [for (_ in sources) 0]; // 0 unvisited, 1 visiting, 2 done
		var ordered:Array<{path:String, text:String}> = [];
		function visit(index:Int):Void {
			if (state[index] != 0)
				return;
			state[index] = 1;
			for (dependency in models[index].dependencies)
				if (indexByName.exists(dependency))
					visit(indexByName.get(dependency));
			state[index] = 2;
			ordered.push(sources[index]);
		}
		for (index in 0...sources.length)
			visit(index);
		return ordered;
	}
}
