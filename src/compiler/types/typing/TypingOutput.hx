package compiler.types.typing;

import compiler.types.Type.AnonymousField;
import compiler.types.Type.CompilerType;
import compiler.types.analysis.ClosureConversion;
import compiler.types.typing.TypeRepresentation.GenericOwnerRepresentation;

/** A shared unit a unit used, and how much of each of the user's lists came before the use. */
private typedef UnitUse = {
	final name:String;
	final requests:Int;
	final conversion:ClosureConversionMark;
	final owners:Int;
	final enums:Int;

	/** The unit the shared unit's anonymous types are attributed to when this is its first use, or null for none. */
	final anonymousOwner:Null<String>;
}

/**
 * What typing a unit produced: the helpers it requested, the lambdas, adapters and other functions closure conversion made
 * for it, the generic owners and enum specializations it needs, the anonymous types it uses, its incremental query records and
 * the shared units (generic function specializations, inline constants) it used.
 *
 * A unit is one function body or the field initializers of one class. Typing it reads only the program view and writes only to
 * its own output, so the outputs do not depend on the order units are typed in. `ProgramTyper` merges them into the program's
 * output in declaration order: a list keeps its first entry of each name, and a shared unit's output is merged where its first
 * user (in that order) used it. The program's output is also where typing outside any unit writes directly.
 */
class TypingOutput {
	/** Whether this is the output of a shared unit, typed for the first body that used it. */
	public final shared:Bool;

	/** How many body contexts were open when the unit began: a shared unit used from inside a body is part of its user's. */
	public final baseDepth:Int;

	public final requests = new HelperRequests();
	public final closureConversion = new ClosureConversion();
	public final records = new UnitRecords();

	final owners:Array<GenericOwnerRepresentation> = [];
	final ownerNames:Map<String, Bool> = [];
	final enums:Array<CompilerType> = [];
	final enumKeys:Array<String> = [];
	final enumNames:Map<String, Bool> = [];
	final uses:Array<UnitUse> = [];

	/** Anonymous types a shared unit's bodies use before any of their own body contexts is open: its user's. */
	final userAnonymousUses:Map<String, Array<AnonymousField>> = [];

	public function new(shared:Bool, baseDepth:Int) {
		this.shared = shared;
		this.baseDepth = baseDepth;
	}

	/** Adds a generic owner to be typed, unless it was requested before. */
	public function requestOwner(owner:GenericOwnerRepresentation):Void {
		if (ownerNames.exists(owner.name))
			return;
		ownerNames.set(owner.name, true);
		owners.push(owner);
	}

	public function ownerCount():Int
		return owners.length;

	public function owner(index:Int):GenericOwnerRepresentation
		return owners[index];

	/** Adds an enum specialization to be declared, unless it was discovered before. */
	public function discoverEnum(name:String, type:CompilerType):Void {
		if (enumNames.exists(name))
			return;
		enumNames.set(name, true);
		enumKeys.push(name);
		enums.push(type);
	}

	public function enumCount():Int
		return enums.length;

	public function enumType(index:Int):CompilerType
		return enums[index];

	/** Attributes an anonymous type to `unit`; null for the user of this shared unit. */
	public function recordAnonymousUse(unit:Null<String>, name:String, fields:Array<AnonymousField>):Void {
		if (unit == null)
			userAnonymousUses.set(name, fields);
		else
			records.recordAnonymousUse(unit, name, fields);
	}

	/** Records that the unit used the shared unit `name` here. */
	public function recordUse(name:String, anonymousOwner:Null<String>):Void
		uses.push({
			name: name,
			requests: requests.count(),
			conversion: closureConversion.mark(),
			owners: owners.length,
			enums: enums.length,
			anonymousOwner: anonymousOwner
		});

	/**
	 * Adds this output to `program`, with the outputs of the shared units it used first (among those not merged yet, in
	 * `merged`) at the points it used them. `user` is the unit this shared unit's own user-attributed anonymous types go to.
	 */
	public function mergeInto(program:TypingOutput, sharedOutputs:Map<String, TypingOutput>, merged:Map<String, Bool>,
			user:Null<String>):Void {
		var requestsFrom = 0,
			conversionFrom:ClosureConversionMark = {functions: 0, storage: 0, environments: 0},
			ownersFrom = 0,
			enumsFrom = 0;
		for (use in uses) {
			appendRange(program, requestsFrom, use.requests, conversionFrom, use.conversion, ownersFrom, use.owners,
				enumsFrom, use.enums);
			requestsFrom = use.requests;
			conversionFrom = use.conversion;
			ownersFrom = use.owners;
			enumsFrom = use.enums;
			if (merged.exists(use.name))
				continue;
			merged.set(use.name, true);
			var output = sharedOutputs.get(use.name);
			if (output != null)
				output.mergeInto(program, sharedOutputs, merged,
					use.anonymousOwner == null ? user : use.anonymousOwner);
		}
		appendRange(program, requestsFrom, requests.count(), conversionFrom, closureConversion.mark(), ownersFrom,
			owners.length, enumsFrom, enums.length);
		records.mergeInto(program.records);
		if (user != null)
			for (name => fields in userAnonymousUses)
				program.records.recordAnonymousUse(user, name, fields);
	}

	function appendRange(program:TypingOutput, requestsFrom:Int, requestsTo:Int, conversionFrom:ClosureConversionMark,
			conversionTo:ClosureConversionMark, ownersFrom:Int, ownersTo:Int, enumsFrom:Int, enumsTo:Int):Void {
		requests.appendTo(program.requests, requestsFrom, requestsTo);
		closureConversion.appendTo(program.closureConversion, conversionFrom, conversionTo);
		for (index in ownersFrom...ownersTo)
			program.requestOwner(owners[index]);
		for (index in enumsFrom...enumsTo)
			program.discoverEnum(enumKeys[index], enums[index]);
	}
}
