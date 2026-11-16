package compiler.types.typing;

import compiler.core.Source.SourceSpan;
import compiler.types.Type.CompilerType;

typedef WireCodecRequest = {
	final type:CompilerType;
	final origin:String;
	final span:SourceSpan;
}

typedef EqualityRequest = {
	final type:CompilerType;
	final origin:String;
	final span:SourceSpan;
}

typedef EnumMethodRequest = {
	final type:CompilerType;
	final method:String;
	final origin:String;
	final span:SourceSpan;
}

typedef EnumInterfaceAdapterRequest = {
	final type:CompilerType;
	final interfaceType:CompilerType;
	final origin:String;
	final span:SourceSpan;
}

/** A synthesized member of an enum abstract (`Flags`, `RawRepresentable`). */
typedef MemberHelperRequest = {
	final owner:String;
	final method:String;
	final origin:String;
	final span:SourceSpan;
}

/**
 * The generated helpers typed code asks for, by helper name. The first request of a name decides its origin: the function
 * the helper is typed in the context of and emitted beside. `ProgramTyper` generates them once the bodies are typed.
 */
class HelperRequests {
	public final wireCodecs:Map<String, WireCodecRequest> = [];
	public final jsonCodecs:Map<String, WireCodecRequest> = [];

	/** Language `==` on declared values follows their one conformance equality. */
	public final valueEqualities:Map<String, EqualityRequest> = [];

	/** Static Type.enumEq comparisons use enum tags and payloads without declaring enum value conformance. */
	public final enumEqualities:Map<String, EqualityRequest> = [];

	/** Concrete enum interface methods requested by statically dispatched calls. */
	public final enumMethods:Map<String, EnumMethodRequest> = [];

	/** Real enum-to-interface conversions need an interface-dispatch object. */
	public final enumInterfaceAdapters:Map<String, EnumInterfaceAdapterRequest> = [];

	/** Hash implementations generated from declared `Hashable` conformance. */
	public final hashes:Map<String, EqualityRequest> = [];

	public final flags:Map<String, MemberHelperRequest> = [];
	public final rawRepresentables:Map<String, MemberHelperRequest> = [];

	public function new() {}

	/** How many helpers have been requested; the generation loop runs until this stops growing. */
	public function count():Int
		return Lambda.count(flags) + Lambda.count(rawRepresentables) + Lambda.count(valueEqualities)
			+ Lambda.count(enumEqualities) + Lambda.count(hashes) + Lambda.count(enumMethods)
			+ Lambda.count(enumInterfaceAdapters) + Lambda.count(wireCodecs) + Lambda.count(jsonCodecs);
}
