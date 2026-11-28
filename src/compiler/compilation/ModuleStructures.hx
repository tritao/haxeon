package compiler.compilation;

import compiler.modules.ModuleState;
import compiler.semantic.InitializerUnit;
import compiler.syntax.Ast.AstAbstract;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstEnum;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstInterface;
import compiler.types.TypedAst.FunctionOriginKind;
import compiler.types.TypedAst.TypedAnonymous;

/**
 * The structures each unit a module holds met when it was typed or registered (`UnitRecords`), by unit: the module's part of the
 * program's anonymous types, which a fresh build, typing every unit, lists. A build lists a unit's structures while the unit stays
 * and is not typed again (`RetainedFromPrevious.structures`); a unit typed again gives its own. Kept with the module
 * (`ModuleState.structures`) and copied with it, so a build that is not taken leaves those of the state it copied.
 *
 * Every structure the module's units met, each once, is made the first time a build asks for it and kept until a unit's record
 * changes, for the declarations it was made under: a build in which nothing of the module is typed again, selected or invalidated
 * lists it without reading the units. A module has a few units with a record, so they are two arrays rather than a map.
 */
class ModuleStructures {
	final units:Array<String>;
	final types:Array<Array<TypedAnonymous>>;

	/** The structures the units the program still has met, each once, under the declarations below. */
	var all:Null<Array<TypedAnonymous>> = null;

	var classes:Null<Array<AstClass>> = null;
	var abstracts:Null<Array<AstAbstract>> = null;
	var enums:Null<Array<AstEnum>> = null;
	var interfaces:Null<Array<AstInterface>> = null;
	var functions:Null<Array<AstFunction>> = null;

	function new(units:Array<String>, types:Array<Array<TypedAnonymous>>) {
		this.units = units;
		this.types = types;
	}

	public function copy():ModuleStructures {
		var result = new ModuleStructures(units.copy(), types.copy());
		result.all = all;
		result.classes = classes;
		result.abstracts = abstracts;
		result.enums = enums;
		result.interfaces = interfaces;
		result.functions = functions;
		return result;
	}

	public function get(unit:String):Null<Array<TypedAnonymous>> {
		var index = units.indexOf(unit);
		return index < 0 ? null : types[index];
	}

	/** Gives `unit` of `state`, which a build copied for writing, the structures `met`, or none when null. */
	public static function set(state:ModuleState, unit:String, met:Null<Array<TypedAnonymous>>):Void {
		var structures = state.structures;
		if (structures == null) {
			if (met == null)
				return;
			structures = new ModuleStructures([], []);
			state.structures = structures;
		}
		var index = structures.units.indexOf(unit);
		if (met != null) {
			if (index < 0) {
				structures.units.push(unit);
				structures.types.push(met);
			} else
				structures.types[index] = met;
		} else if (index >= 0) {
			structures.units.splice(index, 1);
			structures.types.splice(index, 1);
			if (structures.units.length == 0) {
				state.structures = null;
				return;
			}
		}
		structures.all = null;
	}

	/**
	 * The structures of the units of `state` that this build keeps, given the units it `typed`: all the module's units the program
	 * still has, when none of them is typed again and no function of the module is selected or invalidated (`touched` is false);
	 * else each unit's that stays and is not typed again (`stays`).
	 */
	public static function kept(state:ModuleState, typed:Map<String, Bool>, touched:Bool, owners:Map<String, String>,
			selected:Map<String, Bool>, invalidated:Map<String, Bool>):Array<Array<TypedAnonymous>> {
		var structures = state.structures;
		if (structures == null)
			return [];
		var all = structures.all;
		if (all == null || !madeUnder(structures, state)) {
			all = union(structures, state, owners);
			structures.all = all;
			structures.classes = state.canonicalClasses;
			structures.abstracts = state.canonicalAbstracts;
			structures.enums = state.canonicalEnums;
			structures.interfaces = state.canonicalInterfaces;
			structures.functions = state.canonicalProgramFunctions;
		}
		var untouched = !touched;
		if (untouched)
			for (unit in structures.units)
				if (typed.exists(unit)) {
					untouched = false;
					break;
				}
		if (untouched)
			return [all];
		var units = structures.units;
		return [
			for (index in 0...units.length)
				if (!typed.exists(units[index]) && stays(state, units[index], owners, selected, invalidated))
				structures.types[index]
		];
	}

	/**
	 * Whether the program still has `unit` of `state`: a declared function, a field's initializer (`Class.__init.x`), or a function
	 * the module holds (a generated one stays while a build keeps it). Read only of the module's declarations and functions.
	 */
	static function exists(state:ModuleState, unit:String, owners:Map<String, String>):Bool
		return declared(state, unit, owners) || state.typedFunctions.exists(unit);

	/** Whether `unit` stays in this build: declared, or held and neither selected nor invalidated, nor made for an origin that is. */
	static function stays(state:ModuleState, unit:String, owners:Map<String, String>, selected:Map<String, Bool>,
			invalidated:Map<String, Bool>):Bool {
		if (declared(state, unit, owners))
			return true;
		var fn = state.typedFunctions.get(unit);
		return fn != null && !selected.exists(unit) && !invalidated.exists(unit)
			&& (fn.origin == null || fn.originKind == FunctionOriginKind.Specialization
			|| !invalidated.exists(fn.origin));
	}

	static function declared(state:ModuleState, unit:String, owners:Map<String, String>):Bool {
		if (owners.exists(unit))
			return true;
		var owner = InitializerUnit.ownerClass(unit), field = InitializerUnit.field(unit);
		if (owner == null || field == null)
			return false;
		var name = field.substr(field.lastIndexOf(".") + 1);
		for (classDecl in state.canonicalClasses)
			if (classDecl.name == owner) {
				for (candidate in classDecl.fields)
					if (candidate.name == name && candidate.initializer != null)
						return true;
				return false;
			}
		return false;
	}

	static function madeUnder(structures:ModuleStructures, state:ModuleState):Bool
		return structures.classes == state.canonicalClasses && structures.abstracts == state.canonicalAbstracts
			&& structures.enums == state.canonicalEnums && structures.interfaces == state.canonicalInterfaces
			&& structures.functions == state.canonicalProgramFunctions;

	static function union(structures:ModuleStructures, state:ModuleState,
			owners:Map<String, String>):Array<TypedAnonymous> {
		var all:Array<TypedAnonymous> = [], seen:Map<String, Bool> = [];
		for (index in 0...structures.units.length)
			if (exists(state, structures.units[index], owners))
				for (type in structures.types[index])
					if (!seen.exists(type.name)) {
						seen.set(type.name, true);
						all.push(type);
					}
		return all;
	}

	/** Check mode: the structures kept for `state` are those of the units the program still has. */
	public static function check(state:ModuleState, owners:Map<String, String>):Void {
		var structures = state.structures;
		if (structures == null || structures.all == null || !madeUnder(structures, state))
			return;
		var expected = [for (type in union(structures, state, owners)) type.name => true],
			listed = [for (type in structures.all) type.name => true];
		for (name in expected.keys())
			if (!listed.exists(name))
				throw new compiler.core
					.InternalError('module "${state.name}" keeps no structure "$name", which a unit it has met');
		for (name in listed.keys())
			if (!expected.exists(name))
				throw new compiler.core
					.InternalError('module "${state.name}" keeps structure "$name", which no unit it has met');
	}
}
