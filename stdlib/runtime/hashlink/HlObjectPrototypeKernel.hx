package runtime.hashlink;

import runtime.memory.RawPtr;

/** Native mechanism for publishing one already-bound object prototype. */
interface HlObjectPrototypeKernel {
	function publishObjectPrototype(type:RawPtr<HlType>):Void;
}
