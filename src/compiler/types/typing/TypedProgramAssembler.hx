package compiler.types.typing;

import compiler.core.StdlibNames;
import compiler.types.NativeTypeDescriptor.NativeTypeDescriptorData;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedClass;
import compiler.types.TypedAst.TypedEnum;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedInterface;
import compiler.types.TypedAst.TypedNative;
import compiler.types.TypedAst.TypedProgram;

/** Registers final anonymous types and assembles the typed program value. */
class TypedProgramAssembler {
	final session:TypingSession;

	public function new(session:TypingSession)
		this.session = session;

	/** The name the natives' uses are kept under, which no declaration has. */
	static inline final NATIVES = "$natives";

	/** The uses an earlier build made of a declaration, by its name, or null; see `KeptDeclarations.typeUses`. */
	var keptUses:Null<String->Null<ProgramTypeUses>> = null;

	/** Keeps the uses this build registered for a declaration, by its name. */
	var keepUses:Null<(String, ProgramTypeUses) -> Void> = null;

	/** `--check-reuse`: kept uses are made again and compared. */
	var checkUses = false;

	public function bindKeptUses(kept:Null<String->Null<ProgramTypeUses>>, keep:Null<(String, ProgramTypeUses) -> Void>,
			check:Bool):Void {
		keptUses = kept;
		keepUses = keep;
		checkUses = check;
	}

	/**
	 * Registers what the signatures of `functions` and the types of the declarations reach: the structures, enum specializations and
	 * generic owners (`ProgramTypeUses`). A declaration's uses are made once and kept while it is the same object; a function's
	 * structures are its unit's, recorded when its uses are made, so a kept function's stay in its module's record. The natives are
	 * one declaration: their array is the program's while no declaration changes, and they have no origin.
	 */
	public function registerProgramTypes(functions:Array<TypedFunction>, classes:Array<TypedClass>,
			interfaces:Array<TypedInterface>, enums:Array<TypedEnum>,
			natives:Array<TypedNative>):Void {
		for (fn in functions) {
			// Only a generated class's method is registered again as the same function (a generic owner's specialization a build
			// keeps); the uses of any other would be kept for nothing.
			var keeps = fn.physicalOwner != null, kept = keeps ? kept(fn.name, fn) : null, uses = kept;
			if (uses == null || checkUses) {
				var made:Null<ProgramTypeUses> = null;
				for (argument in fn.arguments)
					made = ProgramTypeUses.add(session, made, argument.type);
				made = ProgramTypeUses.add(session, made, fn.result);
				uses = keptOrMade(fn.name, fn, kept, made, keeps);
				var structures = made == null ? null : made.structures;
				if (kept == null && structures != null)
					for (structure in structures)
						session.programOutput.records.recordAnonymousUse(fn.name, structure.name, structure.fields);
			}
			if (uses != null)
				uses.register(session, fn.name);
		}
		for (classDecl in classes) {
			// A struct can reach Dynamic through reflection or a shape-erased generic
			// owner, without any source-level conversion naming its concrete type.
			// Register its declared conformance with its runtime type, independently
			// of which escape the source happened to use. Unused helpers are pruned.
			var origin = classDecl.methods.length > 0 ? classDecl.methods[0].name : functions.length > 0
				? functions[0].name : null;
			if (classDecl.isValue && !classDecl.isNativeValue && origin != null) {
				var type = TInstance(NominalKind.Class,
					classDecl.specializationOrigin == null ? classDecl.name : classDecl.specializationOrigin,
					classDecl.specializationArguments == null ? [] : classDecl.specializationArguments);
				if (!session.representation.containsTypeParameter(type, [])
					&& DeclaredConformance.has(session, type, StdlibNames.EQUATABLE))
					ValueEqualityGenerator.request(session, type, origin, classDecl.span);
			}
			var kept = kept(classDecl.name, classDecl.fields), uses = kept;
			if (uses == null || checkUses) {
				var made:Null<ProgramTypeUses> = null;
				for (field in classDecl.fields)
					made = ProgramTypeUses.add(session, made, field.type);
				uses = keptOrMade(classDecl.name, classDecl.fields, kept, made, true);
			}
			if (uses != null)
				uses.register(session, RuntimeDependencyTracker.TYPE_ORIGIN_PREFIX
					+ (classDecl.specializationOrigin == null ? classDecl.name : classDecl.specializationOrigin));
		}
		for (interfaceDecl in interfaces) {
			var kept = kept(interfaceDecl.name, interfaceDecl.methods), uses = kept;
			if (uses == null || checkUses) {
				var made:Null<ProgramTypeUses> = null;
				for (method in interfaceDecl.methods) {
					for (argument in method.arguments)
						made = ProgramTypeUses.add(session, made, argument);
					made = ProgramTypeUses.add(session, made, method.result);
				}
				uses = keptOrMade(interfaceDecl.name, interfaceDecl.methods, kept, made, true);
			}
			if (uses != null)
				uses.register(session, RuntimeDependencyTracker.TYPE_ORIGIN_PREFIX + interfaceDecl.name);
		}
		for (enumDecl in enums) {
			var kept = kept(enumDecl.name, enumDecl.cases), uses = kept;
			if (uses == null || checkUses) {
				var made:Null<ProgramTypeUses> = null;
				for (enumCase in enumDecl.cases)
					for (parameter in enumCase.params)
						made = ProgramTypeUses.add(session, made, parameter);
				uses = keptOrMade(enumDecl.name, enumDecl.cases, kept, made, true);
			}
			if (uses != null)
				uses.register(session, RuntimeDependencyTracker.TYPE_ORIGIN_PREFIX + enumDecl.name);
		}
		if (natives.length > 0) {
			var kept = kept(NATIVES, natives), uses = kept;
			if (uses == null || checkUses) {
				var made:Null<ProgramTypeUses> = null;
				for (native in natives) {
					for (argument in native.arguments)
						made = ProgramTypeUses.add(session, made, argument);
					made = ProgramTypeUses.add(session, made, native.result);
				}
				uses = keptOrMade(NATIVES, natives, kept, made, true);
			}
			if (uses != null)
				uses.register(session, null);
		}
	}

	/** The uses an earlier build made of `source`, kept again for this build. */
	function kept(name:String, source:Any):Null<ProgramTypeUses> {
		var find = keptUses, keep = keepUses;
		if (find == null || keep == null)
			return null;
		var uses = find(name);
		if (uses == null || uses.source != source)
			return null;
		keep(name, uses);
		return uses;
	}

	/**
	 * The `kept` uses of `name`, which `--check-reuse` holds to those `made` now of `source`, or else `made` (null for none), kept
	 * for later builds when `keeps` and typing has settled them.
	 */
	function keptOrMade(name:String, source:Any, kept:Null<ProgramTypeUses>, made:Null<ProgramTypeUses>,
			keeps:Bool):Null<ProgramTypeUses> {
		if (kept != null) {
			if (!ProgramTypeUses.same(kept, made))
				throw new compiler.core
					.InternalError('--check-reuse: the program type uses kept for "$name" are not those its types give');
			return kept;
		}
		var keep = keepUses;
		if (made != null && keep != null && keeps && made.settled)
			keep(name, made.madeOf(source));
		return made;
	}

	public function assemble(enums:Array<TypedEnum>, interfaces:Array<TypedInterface>, classes:Array<TypedClass>,
			functions:Array<TypedFunction>,
			natives:Array<TypedNative>, nativeTypeDescriptors:Array<NativeTypeDescriptorData>):TypedProgram {
		return {
			nativeAbiTarget: session.nativeAbiTarget,
			genericOwnerAliases: session.representation.genericOwnerAliases(),
			nativeTypeDescriptors: nativeTypeDescriptors,
			enums: enums,
			interfaces: interfaces,
			classes: classes,
			functions: functions,
			closurePlan: session.programOutput.closureConversion.plan(),
			anonymousTypes: orderedAnonymousTypes(),
			natives: natives,
			unboundLocals: session.programOutput.records.unboundLocals.copy(),
			nonExceptionThrows: session.programOutput.records.nonExceptionThrows.copy(),
			lambdaTrailingValues: session.programOutput.records.lambdaTrailingValues.copy()
		};
	}

	public function runtimeDependencies():Array<{
		var functionName:String;
		var target:String;
	}>
		return session.runtimeDependencyTracker.ordered();

	function orderedAnonymousTypes():Array<compiler.types.TypedAst.TypedAnonymous> {
		var names = [for (name in session.anonymousTypes.keys()) name];
		names.sort(Reflect.compare);
		return [for (name in names) {
			name: name, fields: session.anonymousTypes.get(name)
		}];
	}
}
