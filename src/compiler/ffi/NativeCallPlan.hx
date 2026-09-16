package compiler.ffi;

import compiler.ffi.HxiAbi.HxiAbiValue;
import compiler.ffi.HxiModel.HxiResultPolicy;
import compiler.ffi.HxiSemantics.HxiSemanticFunction;

/** How a native call obtains its callee or performs a language-specific ABI operation. */
enum NativeDispatch {
	DirectSymbol;
	IndirectPointer;
	CxxVirtual(vtableIndex:Int, thisAdjustment:Int);
	CxxConstructor;
	CxxDestructor;
}

/** Target-specific call description shared by all native language frontends. */
typedef NativeCallPlan = {
	final name:String;
	final symbol:String;
	final library:Null<String>;
	final arguments:Array<HxiAbiValue>;
	final result:HxiAbiValue;
	final leaf:Bool;
	final callConvention:String;
	final resultPolicy:HxiResultPolicy;
	final semantics:HxiSemanticFunction;
	final dispatch:NativeDispatch;
}
