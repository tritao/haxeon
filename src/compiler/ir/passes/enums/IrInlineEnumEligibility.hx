package compiler.ir.passes.enums;

import compiler.ir.analysis.IrEnumEscapeReach;
import compiler.ir.analysis.IrEnumEscapeReach.IrEscapeResults;
import compiler.ir.reuse.IrWalkRecord;
import compiler.ir.model.Ir;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrBodyBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrTypeIds;
import compiler.ir.passes.objects.IrObjectReflection;
import compiler.ir.passes.values.IrValueInterfaceBoxes;
import compiler.semantic.SemanticSignature;
import compiler.types.typing.EnumRuntimeType;

private typedef EnumUseNode = {
	final parents:Array<Int>;
	final bits:Array<Int>;
	var queued:Bool;
}

/** Conservative first source subset. A rejected enum keeps its nominal storage everywhere in the program. */
@:nullSafety(Strict)
class IrInlineEnumEligibility {
	/** What each function lets escape or keeps in value form (`IrInlineEnumUses`). */
	/** The escape reach of the reflected layouts, which a session keeps (`IrEnumEscapeReach.collectKept`). */
	@:processWide("a kept reach's key, only ever read")
	public static final REFLECTED =
		new compiler.ir.reuse.IrStageMemo
		.IrContributionKey<IrWalkRecord<Bool, IrEscapeResults>>("inline-enum-reflected-reach");

	/** The escape reach of the escape reasons, which a session keeps (`IrEnumEscapeReach.collectEach`). */
	@:processWide("a kept reach's key, only ever read")
	public static final ESCAPES =
		new compiler.ir.reuse.IrStageMemo
		.IrContributionKey<IrWalkRecord<Bool, IrEscapeResults>>("inline-enum-escape-reach");

	@:processWide("a contribution memo's key, only ever read")
	public static final USES =
		new compiler.ir.reuse.IrStageMemo.IrContributionKey<IrInlineEnumUses>("inline-enum-uses");

	public final allowed:Map<String, Bool> = [];
	public final reasons:Map<String, String> = [];
	/** Type descriptors that describe a verified callable boundary for a selected enum. */
	public final callableDescriptors:Map<String, Map<Int, Bool>> = [];

	final objects:Map<String, IrObject>;
	final contracts:Map<String, IrInterface>;
	final declarations:Map<String, IrEnum>;
	final planner:IrInlineEnumLayout;
	final reflectionReach:IrEnumEscapeReach;
	final lineage:Null<compiler.ir.reuse.IrStageMemo.IrLineage>;
	final enumNodes:Map<String, Int> = [];
	final objectNodes:Map<String, Int> = [];
	final interfaceNodes:Map<String, Int> = [];
	final escapeRoots:Map<String, Array<IrType>> = [];
	final escapeOrder:Array<String> = [];
	final names:Array<String>;
	final nodes:Array<EnumUseNode> = [];
	final words:Int;
	final rejected:Array<Int>;

	/**
	 * The enums of `program` that may be lowered to value packets, reading the functions' bodies, encoding a function that has
	 * none.
	 */
	public function new(program:IrProgram, planner:IrInlineEnumLayout, ?reflectableObjects:Array<String>,
			?builder:IrBodyBuilder, ?lineage:compiler.ir.reuse.IrStageMemo.IrLineage) {
		this.planner = planner;
		this.lineage = lineage;
		// What each function lets escape or keeps in value form, read once per version in a session (`IrInlineEnumUses`); the
		// reach follows the closures and map stores the records name.
		var uses = [for (fn in program.functions) IrInlineEnumUses.of(fn, builder, lineage)];
		reflectionReach = new IrEnumEscapeReach(program, _ -> false);
		for (record in uses)
			record.follow(reflectionReach);
		declarations = [for (declaration in program.enums) declaration.name => declaration];
		objects = [for (object in program.objects) object.name => object];
		contracts = [for (contract in program.interfaces) contract.name => contract];
		// Tag enums have no payload storage to classify. Exclude them before allocating graph bitsets.
		names = [for (declaration in program.enums) if (!IrEnumTagStorage.eligible(declaration)) declaration.name];
		words = (names.length + 31) >> 5;
		rejected = [for (_ in 0...words) 0];
		if (names.length == 0) return;
		for (index in 0...names.length) {
			var name = names[index], node = named(enumNodes, name);
			nodes[node].bits[index >> 5] |= 1 << (index & 31);
		}
		for (object in program.objects) {
			var node = named(objectNodes, object.name);
			for (field in object.fields)
				depend(node, field.type);
			if (object.base != null) {
				var base = named(objectNodes, object.base);
				edge(node, base);
				edge(base, node);
			}
			for (contract in object.interfaces)
				edge(named(interfaceNodes, contract), node);
		}
		for (contract in program.interfaces) {
			var node = named(interfaceNodes, contract.name);
			for (base in contract.bases)
				edge(named(interfaceNodes, base), node);
		}
		for (declaration in program.enums)
			for (constructor in declaration.cases)
				for (parameter in constructor.params)
					depend(named(enumNodes, declaration.name), parameter);
		var functions = [for (fn in program.functions) fn.name => fn];
		for (object in program.objects)
			for (method in object.methods) {
				var fn = functions.get(method.functionName.name);
				if (fn == null)
					continue;
				var node = named(objectNodes, object.name);
				for (argument in fn.arguments)
					depend(node, argument.type);
				depend(node, fn.result);
			}
		for (field in program.staticFields) {
			var separator = field.name.lastIndexOf(".");
			if (separator < 0)
				continue;
			var node = objectNodes.get(field.name.substr(0, separator));
			if (node != null)
				depend(node, field.type);
		}
		closeDependencies();
		// Retained fields can survive even when no instruction reads or initializes them. Their container
		// descriptors still carry closure signatures, so apply the same restriction as instruction outputs.
		for (object in program.objects)
			for (field in object.fields)
				containerCallable(field.type);
		for (field in program.staticFields)
			containerCallable(field.type);
		for (declaration in program.enums) if (!IrEnumTagStorage.eligible(declaration)) {
			if (nativePayload(Enum(declaration.name), []))
				block(declaration.name, "canonical native payload layout");
			else if (planner.shape(declaration.name) == null)
				block(declaration.name, "recursive or disproportionate layout");
			else if (EnumRuntimeType.declaration(declaration.name) != declaration.name)
				block(declaration.name, "generic enum transport");
			// Reference payloads retain nominal callable descriptors; do not rewrite one side of their ABI.
			for (constructor in declaration.cases)
				for (parameter in constructor.params)
					callablePayload(parameter);
		}
		// Selecting a larger inline field must never reuse native offsets computed for a boxed enum.
		for (object in program.objects)
			if (object.nativeLayout != null)
				for (field in object.fields)
					value(field.type, "enclosing native layout");
		for (object in program.objects)
			if (!object.isValue)
				for (method in object.methods) {
					var fn = functions.get(method.functionName.name);
					if (fn == null)
						continue;
					for (argument in fn.arguments)
						value(argument.type, "ordinary method signature");
					value(fn.result, "ordinary method signature");
				}
		for (native in program.natives)
			if (!IrArrayRuntimeNatives.isStorage(native.name)) {
				for (argument in native.arguments)
					escape(argument, "native signature");
				escape(native.result, "native signature");
			}
		for (native in program.cNatives) {
			for (argument in native.arguments)
				escape(argument, "C native signature");
			escape(native.result, "C native signature");
		}
		for (index in 0...program.functions.length)
			replay(program.functions[index], uses[index], program.entryPoint);
		// One walk for every reason: an enum is blocked for the first reason, in order, whose roots reach it.
		var rooted = [for (reason in escapeOrder) if (escapeRoots.get(reason) != null) reason],
			reachedEach = reflectionReach.collectEach(ESCAPES, [for (reason in rooted) escapeRoots.get(reason) ?? []],
				supportsCallableEscape, lineage),
			reached:Map<String, Bool> = [];
		for (index in 0...rooted.length)
			for (name in reachedEach[index].keys())
				if (!reached.exists(name)) {
					reached.set(name, true);
					block(name, rooted[index]);
				}
		// Registered layouts are a conservative reflection fallback. Report a traced escape first.
		if (IrObjectReflection.usedByProgram(program)) {
			var reflectedNames = reflectableObjects == null ? [] : reflectableObjects,
				reflected = [for (name in reflectedNames) name => true];
			for (object in program.objects) {
				// Anonymous records have runtime layouts too. A Dynamic/reflection edge can reach
				// one even when it was created inside a Dynamic object literal.
				if (!object.isValue && SemanticSignature.isAnonymousName(object.name))
					reflected.set(object.name, true);
				if (object.isValue || StringTools.startsWith(object.name, IrValueInterfaceBoxes.BOX_PREFIX))
					reflected.set(object.name, true);
			}
			var unsupported = reflectedUnsupportedEnums(reflected);
			for (name in unsupported.keys()) block(name, "registered reflection layout");
		}
		for (name in names)
			if (!reasons.exists(name))
				allowed.set(name, true);
	}

	/** What one function's rows let escape or keep in value form (its record, `IrInlineEnumUses`), and its verified callable descriptors. */
	function replay(fn:IrFunction, uses:IrInlineEnumUses, entryPoint:String):Void {
		if (fn.retention == Expose || fn.name == entryPoint) {
			for (argument in fn.arguments)
				escape(argument.type, "host signature");
			escape(fn.result, "host signature");
		}
		var events = uses.events, index = 0;
		while (index < events.length) {
			var kind = events[index],
				type = IrTypeIds.type(events[index + 1]),
				reason = IrInlineEnumUses.REASONS[events[index + 2]];
			switch kind {
				case IrInlineEnumUses.ESCAPE:
					escape(type, reason);
				case IrInlineEnumUses.ESCAPE_MAP:
					escapeMapReference(type, reason);
				case IrInlineEnumUses.DYNAMIC:
					if (!supportsCallableEscape(type))
						escape(type, reason);
				case IrInlineEnumUses.CAST:
					var out = IrTypeIds.type(events[index + 3]);
					if (!((switch type {
						case Dyn: true;
						default: false;
					}) && supportsCallableEscape(out))) {
						escape(out, reason);
						escape(type, reason);
					}
				case IrInlineEnumUses.VALUE:
					value(type, reason);
				case IrInlineEnumUses.CALLABLE_VALUE:
					callableValue(type, reason, true);
				case IrInlineEnumUses.CONTAINER:
					containerCallable(type);
				default:
					throw new compiler.core.InternalError('Unknown inline enum use $kind');
			}
			index += kind == IrInlineEnumUses.CAST ? 4 : 3;
		}
		var descriptors = uses.descriptors;
		if (descriptors.length == 0)
			return;
		var logical = logicalEnumDescriptorFunction(fn.name),
			validCallableDescriptors:Map<Int, Bool> = [];
		index = 0;
		while (index < descriptors.length) {
			var id = descriptors[index],
				type = IrTypeIds.type(descriptors[index + 1]),
				closures = descriptors[index + 2],
				tests = descriptors[index + 3],
				arrays = descriptors[index + 4],
				others = descriptors[index + 5],
				escapes = descriptors[index + 6] != 0;
			index += IrInlineEnumUses.DESCRIPTOR;
			// The uses of the descriptor, classified as the scan of the rows does: a type test or a closure test that does not
			// verify the descriptor counts as another use.
			var uses = closures + tests + arrays + others,
				callableUse = false,
				referenceUse = false,
				logicalUse = false,
				arrayUse = arrays > 0,
				other = escapes || others > 0;
			if (closures > 0) {
				if (supportsCallableEscape(type))
					callableUse = true;
				else
					other = true;
			}
			if (tests > 0) {
				if (isReferenceTypeDescriptor(type))
					referenceUse = true;
				else if (logical && isSelectedEnumDescriptor(type))
					logicalUse = true;
				else
					other = true;
			}
			var singleUse = uses == 1 && !other;
			if (referenceUse && singleUse && isReferenceTypeDescriptor(type))
				continue;
			if (logicalUse && singleUse && isSelectedEnumDescriptor(type))
				continue;
			if (callableUse && singleUse && supportsCallableEscape(type))
				validCallableDescriptors.set(id, true);
			else if (!arrayUse || other || uses != 1)
				escape(type, "runtime type descriptor");
		}
		if (validCallableDescriptors.keys().hasNext())
			callableDescriptors.set(fn.name, validCallableDescriptors);
	}

	static function logicalEnumDescriptorFunction(name:String):Bool
		return name == IrEnumDynamicDispatch.EQUAL || name == IrEnumDynamicDispatch.REFLECT
			|| StringTools.startsWith(name, "$enum-dynamic-test:");

	function isSelectedEnumDescriptor(type:IrType):Bool
		return switch type {
			case Enum(name): planner.shape(name) != null;
			default: false;
		};

	/** A class type check consumes nominal identity without observing the class's field layout. */
	function isReferenceTypeDescriptor(type:IrType):Bool
		return switch type {
			case Obj(name):
				var object = objects.get(name);
				object != null && !object.isValue;
			default: false;
		};

	// Native structs need the independent canonical layout, not target-specific pointer offsets.
	function nativePayload(type:IrType, seen:Array<String>):Bool
		return switch type {
			case Enum(name):
				if (seen.contains(name)) false;
				else {
					var declaration = declarations.get(name);
					declaration != null && Lambda.exists(declaration.cases,
						item -> Lambda.exists(item.params, p -> nativePayload(p, seen.concat([name]))));
				}
			case Obj(name): var object = objects.get(name);
				object != null && object.isValue && (object.nativeLayout != null
					|| Lambda.exists(object.fields, field -> nativePayload(field.type, seen)));
			case Nullable(inner): nativePayload(inner, seen);
			default: false;
		}

	function named(map:Map<String, Int>, name:String):Int {
		var found = map.get(name);
		if (found != null)
			return found;
		var index = nodes.length;
		nodes.push({parents: [], bits: [for (_ in 0...words) 0], queued: false});
		map.set(name, index);
		return index;
	}

	function edge(parent:Int, child:Int):Void
		nodes[child].parents.push(parent);

	function depend(parent:Int, type:IrType):Void
		switch type {
			case Enum(name):
				edge(parent, named(enumNodes, name));
			case Obj(name):
				var object = objects.get(name);
				// Ordinary classes are reference leaves in every value layout. Their fields and methods matter only when
				// that class itself crosses a Dynamic/reflection or typed-call boundary.
				if (object != null && object.isValue)
					edge(parent, named(objectNodes, name));
			case Virtual(name):
				edge(parent, named(interfaceNodes, name));
			case Array(inner), Iterator(inner), Nullable(inner):
				depend(parent, inner);
			case Function(arguments, result):
				for (argument in arguments)
					depend(parent, argument);
				depend(parent, result);
			default:
		}

	function closeDependencies():Void {
		var pending:Array<Int> = [];
		for (index in enumNodes) {
			pending.push(index);
			nodes[index].queued = true;
		}
		var cursor = 0;
		while (cursor < pending.length) {
			var node = nodes[pending[cursor++]];
			node.queued = false;
			for (parent in node.parents) {
				var target = nodes[parent], changed = false;
				for (word in 0...words) {
					var merged = target.bits[word] | node.bits[word];
					if (merged != target.bits[word]) {
						target.bits[word] = merged;
						changed = true;
					}
				}
				if (changed && !target.queued) {
					pending.push(parent);
					target.queued = true;
				}
			}
		}
	}

	function mark(node:Null<Int>, reason:String):Void {
		if (node == null)
			return;
		var bits = nodes[node].bits;
		for (word in 0...words) {
			var fresh = bits[word] & ~rejected[word];
			if (fresh == 0)
				continue;
			rejected[word] |= fresh;
			for (bit in 0...32)
				if ((fresh & (1 << bit)) != 0) {
					reasons.set(names[(word << 5) + bit], reason);
				}
		}
	}

	/** Direct selected enum arguments/results can use the established scalar closure ABI and enum escape adapters. */
	public function supportsCallableEscape(type:IrType):Bool {
		var signature:Null<IrType> = switch type {
			case Function(_, _): type;
			case Nullable(inner): switch inner {
					case Function(_, _): inner;
					default: null;
				};
			default: null;
		};
		if (signature == null) return false;
		var parts:Array<IrType> = switch signature {
			case Function(arguments, result): arguments.concat([result]);
			default: [];
		};
		var found = false;
		for (part in parts)
			switch part {
				case Enum(name) if (planner.shape(name) != null && EnumRuntimeType.declaration(name) == name
					&& !nativePayload(Enum(name), [])):
					found = true;
				default:
					if (hasSelectedEnum(part, [])) return false;
			}
		return found;
	}

	function hasSelectedEnum(type:IrType, seenValues:Array<String>):Bool
		return switch type {
			case Enum(name): planner.shape(name) != null;
			case Nullable(inner), Array(inner), Iterator(inner): hasSelectedEnum(inner, seenValues);
			case Function(arguments, result): Lambda.exists(arguments,
				argument -> hasSelectedEnum(argument, seenValues)) || hasSelectedEnum(result, seenValues);
			case Obj(name):
				var object = objects.get(name);
				object != null && object.isValue && !seenValues.contains(name)
					&& Lambda.exists(object.fields, field -> hasSelectedEnum(field.type, seenValues.concat([name])));
			default: false;
		};

	function reflectedUnsupportedEnums(reflected:Map<String, Bool>):Map<String, Bool> {
		var roots:Array<IrType> = [for (name in reflected.keys()) Obj(name)];
		return reflectionReach.collectKept(REFLECTED, roots, supportsCallableEscape, lineage);
	}

	function block(name:String, reason:String):Void {
		if (enumNodes.exists(name)) mark(enumNodes.get(name), reason);
	}

	/** Map reference slots retain managed object pointers; only boxed value packets cross this boundary. */
	function escapeMapReference(type:IrType, reason:String):Void
		switch type {
			case Enum(_): escapeType(type, reason);
			case Nullable(inner): escapeMapReference(inner, reason);
			case Obj(name):
				var object = objects.get(name);
				if (object != null && object.isValue) escapeType(type, reason);
			case Function(_, _): escapeType(type, reason);
			default:
		}

	function escape(type:IrType, reason:String):Void escapeType(type, reason);

	function escapeType(type:IrType, reason:String):Void {
		var roots = escapeRoots.get(reason);
		if (roots == null) {
			roots = [];
			escapeRoots.set(reason, roots);
			escapeOrder.push(reason);
		}
		if (reason == "native signature" || reason == "C native signature") IrEnumEscapeReach.addNativeRoot(roots,
			type);
		else roots.push(type);
	}

	function value(type:IrType, reason:String):Void
		switch type {
			case Enum(name):
				block(name, reason);
			case Nullable(inner):
				value(inner, reason);
			case Obj(name):
				var object = objects.get(name);
				if (object != null && object.isValue)
					for (field in object.fields)
						value(field.type, reason);
			default:
		}

	function callableValue(type:IrType, reason:String, allowInlineEnumEscape:Bool = false):Void
		switch type {
			case Function(arguments, result):
				if (allowInlineEnumEscape && supportsCallableEscape(type)) return;
				for (argument in arguments)
					value(argument, reason);
				value(result, reason);
			default:
		}

	function callablePayload(type:IrType):Void
		switch type {
			case Function(_, _):
				callableValue(type, "nominal callable payload");
			case Nullable(inner), Array(inner), Iterator(inner):
				callablePayload(inner);
			case Obj(name):
				var object = objects.get(name);
				if (object != null && object.isValue)
					for (field in object.fields)
						callablePayload(field.type);
			default:
		}

	function containerCallable(type:IrType):Void
		switch type {
			case Array(inner), Iterator(inner):
				callablePayload(inner);
			case Nullable(inner):
				containerCallable(inner);
			default:
		}
}

/**
 * What one function's rows let escape or keep in value form, for the inline enum eligibility (`IrInlineEnumEligibility`), by type
 * ids of the body's table: a list of uses, each a kind, a type and a reason (`REASONS`), kept once each in the order the rows give
 * them; its type descriptors with their uses by kind; and the closures it makes and its map stores, which the escape reach follows.
 * It depends on the body alone, so a session keeps it by the function's version (`IrStageMemos.inlineEnumUses`).
 */
@:nullSafety(Strict)
class IrInlineEnumUses {
	public static inline final ESCAPE = 0;
	public static inline final ESCAPE_MAP = 1;

	/** A value turned `Dyn`: an escape unless a callable the enum escape adapters support. */
	public static inline final DYNAMIC = 2;

	/** A checked cast, from the type to the next one (four entries): an escape of both unless a callable out of `Dyn`. */
	public static inline final CAST = 3;

	public static inline final VALUE = 4;
	public static inline final CALLABLE_VALUE = 5;
	public static inline final CONTAINER = 6;

	/** The entries of a descriptor: its value id, its type, its closure tests, type tests, array allocations, other uses, escape. */
	public static inline final DESCRIPTOR = 7;

	@:processWide("the reasons a use names, by number, only ever read")
	public static final REASONS = [
		"exception escape", "native reference map storage", "Dynamic escape", "checked escape",
		"ordinary method receiver",
		"ordinary method result", "ordinary method argument", "bound value receiver", "bound value method",
		"unlowered enum comparison", ""
	];

	public final events:Array<Int> = [];
	public final descriptors:Array<Int> = [];

	/** Pairs of a closure's type and its receiver's. */
	public final closures:Array<Int> = [];

	/** Triples of a map's type, the key's and the value's. */
	public final mapStores:Array<Int> = [];

	final kept:Map<Int, Bool> = [];

	function new() {}

	public static function of(fn:IrFunction, builder:Null<IrBodyBuilder>,
			lineage:Null<compiler.ir.reuse.IrStageMemo.IrLineage>):IrInlineEnumUses {
		var version = lineage == null ? 0 : lineage.versionOf(fn);
		if (lineage == null || version == 0)
			return read(fn.encodedBody(builder));
		var memo = lineage.memos.contribution(IrInlineEnumEligibility.USES), known = memo.get(version);
		if (known == null) {
			known = read(fn.encodedBody(builder));
			memo.keep(version, known);
		} else if (lineage.checks && !known.same(read(fn.encodedBody(builder))))
			throw new compiler.core
				.InternalError('--check-reuse: the inline enum uses reused for ${fn.name} differ from its body');
		return known;
	}

	function same(other:IrInlineEnumUses):Bool
		return events.join(",") == other.events.join(",") && descriptors.join(",") == other.descriptors.join(",")
			&& closures.join(",") == other.closures.join(",") && mapStores.join(",") == other.mapStores.join(",");

	/** Gives `reach` the closures and map stores of the function. */
	public function follow(reach:IrEnumEscapeReach):Void {
		var index = 0;
		while (index < closures.length) {
			reach.closureEnvironment(closures[index], closures[index + 1]);
			index += 2;
		}
		index = 0;
		while (index < mapStores.length) {
			reach.mapContent(mapStores[index], mapStores[index + 1], mapStores[index + 2]);
			index += 3;
		}
	}

	/** Records a use of `kind` for the type of id `type`, once: a use repeated changes nothing the eligibility decides. */
	function use(kind:Int, type:Int, reason:Int):Void {
		var key = (kind << 28) | (reason << 24) | type;
		if (type < 1 << 24) {
			if (kept.exists(key))
				return;
			kept.set(key, true);
		}
		events.push(kind);
		events.push(type);
		events.push(reason);
	}

	/** Whether a container use of the type of id `type` can block an enum (`IrInlineEnumEligibility.containerCallable`). */
	static function container(type:IrType):Bool
		return switch type {
			case Array(_), Iterator(_): true;
			case Nullable(inner): container(inner);
			default: false;
		};

	static function read(body:IrBody):IrInlineEnumUses {
		var uses = new IrInlineEnumUses();
		var descriptors:Null<Map<Int, Int>> = null, nulls:Map<Int, Bool> = [];
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				switch body.opcode(row) {
					case IrOpcode.TypeValue:
						if (descriptors == null)
							descriptors = [];
						var out:Int = body.output(row);
						descriptors.set(out, uses.descriptors.length);
						for (entry in [out, body.aux(row), 0, 0, 0, 0, 0])
							uses.descriptors.push(entry);
					case IrOpcode.ConstNull:
						nulls.set(body.output(row), true);
					case IrOpcode.InstanceClosure:
						uses.closures.push(body.valueTypeId(body.output(row)));
						uses.closures.push(body.valueTypeId(body.operand(row, 0)));
					case IrOpcode.Call if (body.operandCount(row) >= 3
						&& IrEnumEscapeReach.mapSetter(body.symbol(row).name)):
						var count = body.operandCount(row);
						uses.mapStores.push(body.valueTypeId(body.operand(row, 0)));
						uses.mapStores.push(body.valueTypeId(body.operand(row, 1)));
						uses.mapStores.push(body.valueTypeId(body.operand(row, count - 1)));
					default:
				}
				row = body.nextRow(row);
			}
		}
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var opcode = body.opcode(row);
				if (opcode.isTerminator()) {
					switch opcode {
						case IrOpcode.Throw, IrOpcode.Rethrow:
							uses.use(ESCAPE, body.valueTypeId(body.operand(row, 0)), 0);
						case IrOpcode.Return, IrOpcode.Branch, IrOpcode.Switch
							if (descriptors != null && descriptors.exists(body.operand(row, 0))):
							uses.descriptors[(descriptors.get(body.operand(row, 0)) ?? 0) + 6] = 1;
						default:
					}
					row = body.nextRow(row);
					continue;
				}
				if (descriptors != null)
					for (inputIndex in 0...body.operandCount(row)) {
						var input:Int = body.operand(row, inputIndex), at = descriptors.get(input);
						if (at == null)
							continue;
						// Closure tests, type tests, array allocations, then other uses (a phi's among them).
						var callTarget = opcode == IrOpcode.Call && body.operandCount(row) == 2
							&& body.operand(row, 1) == input ? body.symbol(row).name : null;
						var slot = opcode == IrOpcode.Phi ? 5 : callTarget == "__closure_is_of_type" ? 2 : callTarget
							== "__std_is_exact_type"
							|| callTarget == "__std_is_of_type" ? 3 : callTarget == "__array_alloc_typed_ref" ? 4 : 5;
						uses.descriptors[at + slot]++;
					}
				switch opcode {
					case IrOpcode.Call:
						var name = body.symbol(row).name;
						if (StringTools.startsWith(name, "__map_") && StringTools.contains(name, "_ref_")) {
							var count = body.operandCount(row);
							switch name.substr(name.lastIndexOf("_ref_") + 5) {
								case "set" if (count >= 3):
									uses.use(ESCAPE_MAP, body.valueTypeId(body.operand(row, count - 1)), 1);
								case "get" | "values" | "handles":
									uses.use(ESCAPE_MAP, body.valueTypeId(body.output(row)), 1);
								default:
							}
						}
					case IrOpcode.ToDyn:
						uses.use(DYNAMIC, body.valueTypeId(body.operand(row, 0)), 2);
					case IrOpcode.SafeCast:
						uses.events.push(CAST);
						uses.events.push(body.valueTypeId(body.operand(row, 0)));
						uses.events.push(3);
						uses.events.push(body.valueTypeId(body.output(row)));
					case IrOpcode.MethodCall:
						// Interface packets have a verified typed table; ordinary value calls do not yet share it.
						switch body.valueType(body.operand(row, 0)) {
							case Virtual(_):
							default:
								uses.use(VALUE, body.valueTypeId(body.operand(row, 0)), 4);
								uses.use(VALUE, body.valueTypeId(body.output(row)), 5);
								for (index in 1...body.operandCount(row))
									uses.use(VALUE, body.valueTypeId(body.operand(row, index)), 6);
						}
					case IrOpcode.InstanceClosure:
						switch body.valueType(body.operand(row, 0)) {
							case Virtual(_):
							case Obj(name) if (StringTools.startsWith(name,
								compiler.semantic.LambdaName.ENVIRONMENT_PREFIX)):
							default:
								uses.use(VALUE, body.valueTypeId(body.operand(row, 0)), 7);
								uses.use(CALLABLE_VALUE, body.valueTypeId(body.output(row)), 8);
						}
					case IrOpcode.Equal:
						var left = body.operand(row, 0), right = body.operand(row, 1);
						if (!nulls.exists(left) && !nulls.exists(right)) {
							uses.use(VALUE, body.valueTypeId(left), 9);
							uses.use(VALUE, body.valueTypeId(right), 9);
						}
					default:
				}
				var out = body.output(row);
				if (out.exists() && container(body.valueType(out)))
					uses.use(CONTAINER, body.valueTypeId(out), 10);
				row = body.nextRow(row);
			}
		}
		return uses;
	}
}
