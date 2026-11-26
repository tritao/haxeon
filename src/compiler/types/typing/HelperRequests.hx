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

/** A copy of a `Dynamic` record into the anonymous structure (or array of them) `type`. */
typedef DynamicStructureRequest = {
	final type:CompilerType;
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

/** One request, as a unit's output records it in order. */
enum HelperRequest {
	WireCodecHelper(name:String, request:WireCodecRequest);
	JsonCodecHelper(name:String, request:WireCodecRequest);
	ValueEqualityHelper(name:String, request:EqualityRequest);
	EnumEqualityHelper(name:String, request:EqualityRequest);
	EnumMethodHelper(name:String, request:EnumMethodRequest);
	EnumInterfaceAdapterHelper(name:String, request:EnumInterfaceAdapterRequest);
	HashHelper(name:String, request:EqualityRequest);
	FlagsHelper(name:String, request:MemberHelperRequest);
	RawRepresentableHelper(name:String, request:MemberHelperRequest);
	DynamicStructureHelper(name:String, request:DynamicStructureRequest);
}

/**
 * The generated helpers typed code asks for, by helper name. The first request of a name decides its origin: the function
 * the helper is typed in the context of and emitted beside. A unit's output keeps the requests its unit made, in order; the
 * program's keeps them merged in unit order (see `TypingOutput`), and `ProgramTyper` generates them once the bodies are typed.
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

	/** `Dynamic` to anonymous structure copies, one per target type. */
	public final dynamicStructures:Map<String, DynamicStructureRequest> = [];

	/** The first request of each name, in the order they were made. */
	final entries:Array<HelperRequest> = [];

	public function new() {}

	/**
	 * The unit whose reads are what helper `request` read (`TypingSession.requestHelper`): the helper function, or an interface
	 * adapter's constructor, the adapter being a class. A codec has none: one codec serves every root that reaches its type, so
	 * the code asking for a codec reads the wire shapes the codecs are made from itself (`WireCodecGenerator.readWireShape`).
	 */
	public static function unitOf(request:HelperRequest):Null<String>
		return switch request {
			case ValueEqualityHelper(name, _), EnumEqualityHelper(name, _), HashHelper(name, _): name;
			case EnumMethodHelper(name, _), FlagsHelper(name, _), RawRepresentableHelper(name, _): name;
			case DynamicStructureHelper(name, _): name;
			case EnumInterfaceAdapterHelper(name, _): name + ".new";
			case WireCodecHelper(_, _), JsonCodecHelper(_, _): null;
		};

	/** How many helpers have been requested; the generation loop runs until this stops growing. */
	public function count():Int
		return entries.length;

	/** Records `request` unless a helper of its kind and name was requested before; returns whether it was new. */
	public function add(request:HelperRequest):Bool {
		var added = switch request {
			case WireCodecHelper(name, value): addTo(wireCodecs, name, value);
			case JsonCodecHelper(name, value): addTo(jsonCodecs, name, value);
			case ValueEqualityHelper(name, value): addTo(valueEqualities, name, value);
			case EnumEqualityHelper(name, value): addTo(enumEqualities, name, value);
			case EnumMethodHelper(name, value): addTo(enumMethods, name, value);
			case EnumInterfaceAdapterHelper(name, value): addTo(enumInterfaceAdapters, name, value);
			case HashHelper(name, value): addTo(hashes, name, value);
			case FlagsHelper(name, value): addTo(flags, name, value);
			case RawRepresentableHelper(name, value): addTo(rawRepresentables, name, value);
			case DynamicStructureHelper(name, value): addTo(dynamicStructures, name, value);
		};
		if (added)
			entries.push(request);
		return added;
	}

	/** Adds to `target` the requests from position `from` to `to` of this record, the first of each name winning. */
	public function appendTo(target:HelperRequests, from:Int, to:Int):Void
		for (index in from...to)
			target.add(entries[index]);

	static function addTo<T>(requests:Map<String, T>, name:String, request:T):Bool {
		if (requests.exists(name))
			return false;
		requests.set(name, request);
		return true;
	}
}
