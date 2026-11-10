package compiler.ir;

import compiler.ir.IrStaticNullChecks.IrStaticCheckCache;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypeRelations;
import compiler.runtime.RuntimeType;
import compiler.runtime.PlatformAbi;
import compiler.types.typing.HashGenerator;
import compiler.types.typing.ValueEqualityGenerator;
import compiler.types.analysis.ControlFlow;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.ValueCopyLayout;
import compiler.types.TypedAst.TypedClass;
import compiler.types.TypedAst.TypedEnum;
import compiler.types.TypedAst.TypedInterface;
import compiler.types.TypedAst.TypedProgram;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.TypedAst.TypedSwitchCase;
import compiler.types.TypedAst.TypedSwitchBinding;
import compiler.types.TypedAst.TypedSwitchPredicate;
import compiler.types.TypedAst.TypedSwitchArrayPattern;
import compiler.types.TypedAst.TypedCaptureSource;
import compiler.ir.cfg.Cfg.CfgFunction;
import compiler.ir.cfg.Cfg.CfgBlock;
import compiler.ir.cfg.Cfg.CfgValue;
import compiler.ir.cfg.Cfg.CfgArgument;
import compiler.ir.cfg.CfgBuilder;
import compiler.ir.cfg.CfgLoopContext;
import compiler.ir.cfg.SsaBuilder;
import compiler.ir.cfg.CfgIteratorReplacement;
import compiler.ir.IrBuilder;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrCNative;
import compiler.ir.Ir.IrObject;
import compiler.ir.Ir.IrObjectField;
import compiler.ir.Ir.IrObjectMethod;
import compiler.ir.Ir.IrInterface;
import compiler.ir.Ir.IrEnum;
import compiler.ir.Ir.IrStaticField;

/**
 * What the IR generator and the IR passes know about the whole typed program, derived from it once per build: enum layouts, which
 * classes are value classes, class bases, generic owners, equatable and observable hierarchies and interface contracts. Immutable
 * once built; `inputState` renders all of it as one comparable text.
 */
class ProgramFacts {
	public var enumConstructorCounts:Map<String, Int> = [];
	public var enumEquatableTypes:Map<String, Bool> = [];
	public var enumPayloadTypes:Map<String, Bool> = [];
	public var valueClasses:Map<String, Bool> = [];
	public var classBases:Map<String, String> = [];
	public var genericOwnerAliases:Map<String, String> = [];
	public var typedInterfaceContracts:Map<String, TypedInterface> = [];
	public var genericClasses:Map<String, Bool> = [];
	public var genericOwnerOrigins:Map<String, String> = [];
	public var equatableTypes:Map<String, Bool> = [];
	public var observableClasses:Map<String, Bool> = [];
	public var observableStateOwners:Map<String, String> = [];
	public var observableFieldBits:Map<String, Map<String, Int>> = [];

	/** Derived on every build, like the binding it replaces; keeping it on the identity of the typed program is the compiler-architecture M4 item. */
	public static function of(typed:TypedProgram):ProgramFacts {
		var facts = new ProgramFacts();
		facts.bindEnumConstructors(typed.enums);
		facts.bindClasses(typed.classes, typed.interfaces, typed.genericOwnerAliases);
		return facts;
	}

	/** No classes, enums or interfaces: for code that lowers types or runs a pass on a program built by hand. */
	public static function empty():ProgramFacts
		return new ProgramFacts();

	function new() {}

	/**
	 * Everything the IR passes read from this class, as one comparable text: the program state `bindEnumConstructors` and
	 * `bindClasses` derive from the typed program, and the target flags. The state a build produces while generating (generated
	 * objects, flat and inline value objects, serials) is not an input and is not part of it.
	 */
	public function inputState(profile:TargetProfile):String {
		var out = new StringBuf();
		function section(label:String, keys:Array<String>, render:String->String):Void {
			keys.sort(Reflect.compare);
			out.add(label + "{");
			for (key in keys)
				out.add(key.length + ":" + key + "=" + render(key) + ",");
			out.add("}\n");
		}
		function flag(value:Null<Bool>):String {
			if (value == null)
				throw "Missing Boolean fact while computing pipeline inputs";
			return value ? "1" : "0";
		}
		function text(value:Null<String>):String
			return value == null ? "-" : value.length + ":" + value;
		section("enumConstructorCounts", [for (key in enumConstructorCounts.keys()) key], key -> Std.string(enumConstructorCounts.get(key)));
		section("enumEquatableTypes", [for (key in enumEquatableTypes.keys()) key], key -> flag(enumEquatableTypes.get(key)));
		section("enumPayloadTypes", [for (key in enumPayloadTypes.keys()) key], key -> flag(enumPayloadTypes.get(key)));
		section("valueClasses", [for (key in valueClasses.keys()) key], key -> flag(valueClasses.get(key)));
		section("classBases", [for (key in classBases.keys()) key], key -> text(classBases.get(key)));
		section("genericOwnerAliases", [for (key in genericOwnerAliases.keys()) key], key -> text(genericOwnerAliases.get(key)));
		section("genericClasses", [for (key in genericClasses.keys()) key], key -> flag(genericClasses.get(key)));
		section("genericOwnerOrigins", [for (key in genericOwnerOrigins.keys()) key], key -> text(genericOwnerOrigins.get(key)));
		section("equatableTypes", [for (key in equatableTypes.keys()) key], key -> flag(equatableTypes.get(key)));
		section("observableClasses", [for (key in observableClasses.keys()) key], key -> flag(observableClasses.get(key)));
		section("observableStateOwners", [for (key in observableStateOwners.keys()) key], key -> text(observableStateOwners.get(key)));
		section("observableFieldBits", [for (key in observableFieldBits.keys()) key], key -> {
			var bits = observableFieldBits.get(key);
			if (bits == null)
				throw 'Missing Observable field facts for "$key"';
			var names = [for (name in bits.keys()) name];
			names.sort(Reflect.compare);
			[for (name in names) name + ":" + bits.get(name)].join(";");
		});
		section("typedInterfaceContracts", [for (key in typedInterfaceContracts.keys()) key], key -> Std.string(typedInterfaceContracts.get(key)));
		out.add("target{" + profile.key() + "}");
		return out.toString();
	}

	/** Supply enum layout information needed by compiler-generated key adapters. */
	function bindEnumConstructors(enums:Array<TypedEnum>):Void {
		enumConstructorCounts = [];
		enumEquatableTypes = [];
		enumPayloadTypes = [];
		for (enumDecl in enums) {
			for (constructor in enumDecl.cases)
				if (constructor.params.length > 0)
					enumPayloadTypes.set(enumDecl.name, true);
			if (enumDecl.equatable == true)
				enumEquatableTypes.set(enumDecl.name, true);
			enumConstructorCounts.set(enumDecl.name, enumDecl.cases.length);
		}
	}

	/** Native runtime dynamic objects for `{}` literals; otherwise they allocate `PlatformAbi.DYNAMIC_OBJECT_CLASS`. */
	/** Supply the program's classes: which are value classes (see `isHeaderlessValueClass`) and what each extends (see `isUpcast`). */
	function bindClasses(classes:Array<TypedClass>, ?interfaces:Array<TypedInterface>, ?ownerAliases:Map<String, String>):Void {
		valueClasses = [];
		genericOwnerAliases = ownerAliases == null ? [] : ownerAliases;
		genericClasses = [];
		genericOwnerOrigins = [];
		classBases = [];
		equatableTypes = [];
		observableClasses = [];
		observableStateOwners = [];
		observableFieldBits = [];
		typedInterfaceContracts = [];
		var interfaceBases:Map<String, Array<String>> = [];
		var classesByName:Map<String, TypedClass> = [];
		if (interfaces != null)
			for (interfaceDecl in interfaces) {
				interfaceBases.set(interfaceDecl.name, interfaceDecl.bases);
				typedInterfaceContracts.set(interfaceDecl.name, interfaceDecl);
			}
		for (classDecl in classes) {
			classesByName.set(classDecl.name, classDecl);
			if (classDecl.specializationOrigin != null)
				genericOwnerOrigins.set(classDecl.name, classDecl.specializationOrigin);
			if (classDecl.genericParameters != null && classDecl.genericParameters.length > 0)
				genericClasses.set(classDecl.name, true);
			if (classDecl.isValue)
				valueClasses.set(Std.string(classDecl.name), true);
			if (classDecl.base != null)
				classBases.set(Std.string(classDecl.name), classDecl.base);
		}
		function extendsEquatable(name:String, visiting:Map<String, Bool>):Bool {
			if (name == "Equatable" || name == "Hashable")
				return true;
			if (visiting.exists(name))
				return false;
			visiting.set(name, true);
			var bases = interfaceBases.get(name);
			if (bases != null)
				for (base in bases)
					if (extendsEquatable(base, visiting))
						return true;
			return false;
		}
		function classIsEquatable(name:String, visiting:Map<String, Bool>):Bool {
			if (equatableTypes.exists(name))
				return true;
			if (visiting.exists(name))
				return false;
			visiting.set(name, true);
			var declaration = classesByName.get(name);
			if (declaration == null)
				return false;
			for (interfaceName in declaration.interfaces)
				if (extendsEquatable(interfaceName, [])) {
					equatableTypes.set(name, true);
					return true;
				}
			if (declaration.base != null && classIsEquatable(declaration.base, visiting)) {
				equatableTypes.set(name, true);
				return true;
			}
			return false;
		}
		for (classDecl in classes)
			classIsEquatable(classDecl.name, []);
		function extendsObservable(name:String, visiting:Map<String, Bool>):Bool {
			if (name == "Observable")
				return true;
			if (visiting.exists(name))
				return false;
			visiting.set(name, true);
			var bases = interfaceBases.get(name);
			if (bases != null)
				for (base in bases)
					if (extendsObservable(base, visiting))
						return true;
			return false;
		}
		function classIsObservable(name:String, visiting:Map<String, Bool>):Bool {
			if (observableClasses.exists(name))
				return true;
			if (visiting.exists(name))
				return false;
			visiting.set(name, true);
			var declaration = classesByName.get(name);
			if (declaration == null)
				return false;
			for (interfaceName in declaration.interfaces)
				if (extendsObservable(interfaceName, [])) {
					observableClasses.set(name, true);
					return true;
				}
			if (declaration.base != null && classIsObservable(declaration.base, visiting)) {
				observableClasses.set(name, true);
				return true;
			}
			return false;
		}
		function orderedFields(name:String, visiting:Map<String, Bool>):Array<compiler.types.TypedAst.TypedField> {
			if (visiting.exists(name))
				return [];
			visiting.set(name, true);
			var declaration = classesByName.get(name),
				result:Array<compiler.types.TypedAst.TypedField> = [];
			if (declaration == null)
				return result;
			if (declaration.base != null)
				result = orderedFields(declaration.base, visiting);
			for (field in declaration.fields)
				if (!field.isStatic && IrProgramAssembler.hasPhysicalStorage(field) && !hasUnobservableMetadata(field.metadata))
					result.push(field);
			return result;
		}
		function stateOwner(name:String, visiting:Map<String, Bool>):String {
			var prior = observableStateOwners.get(name);
			if (prior != null)
				return prior;
			if (visiting.exists(name))
				return name;
			visiting.set(name, true);
			var declaration = classesByName.get(name);
			if (declaration == null)
				return name;
			var owner = declaration.base != null
				&& classIsObservable(declaration.base, []) ? stateOwner(declaration.base, visiting) : name;
			observableStateOwners.set(name, owner);
			return owner;
		}
		for (classDecl in classes)
			if (classIsObservable(classDecl.name, [])) {
				var fields = orderedFields(classDecl.name, []),
					byName:Map<String, Int> = [];
				for (index in 0...fields.length)
					byName.set(fields[index].name, index);
				observableFieldBits.set(classDecl.name, byName);
				stateOwner(classDecl.name, []);
			}
	}

	public function genericOwnerOrigin(name:String):String {
		var origin = genericOwnerOrigins.get(name);
		return origin == null ? name : origin;
	}

	function hasUnobservableMetadata(metadata:Array<compiler.syntax.Ast.AstMetadata>):Bool {
		for (entry in metadata)
			if (entry.name == "unobservable")
				return true;
		return false;
	}

	/** The object field carrying this observable hierarchy's shared dependency source. */
	public function observableStateOwner(className:String):Null<String>
		return observableStateOwners.get(className);

	public function observableNamedFieldBit(className:String, fieldName:String):Null<Int> {
		var fields = observableFieldBits.get(className);
		return fields == null ? null : fields.get(fieldName);
	}

	/** Field reservation for an object's concrete Observable class. */
	public function observableClassFieldCount(className:String):Null<Int> {
		var fields = observableFieldBits.get(className);
		if (fields == null)
			return null;
		var count = 0;
		for (bit in fields)
			if (bit >= count)
				count = bit + 1;
		return count < 1 ? 1 : count;
	}
}
