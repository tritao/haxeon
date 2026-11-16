package compiler.ffi;

import compiler.core.Source.SourceSpan;
import compiler.ffi.HxiModel.HxiDeclaration;
import compiler.ffi.HxiModel.HxiInterface;
import compiler.ir.Ir.IrCNative;

typedef FfiInterfaceSource = {
	final path:String;
	final text:String;
}

typedef FfiProjectionSource = {
	final path:String;
	final text:String;
}

/** Immutable source snapshot used when rebuilding a compiler candidate. */
class FfiConfiguration {
	final interfaces:Array<FfiInterfaceSource>;
	final projections:Array<FfiProjectionSource>;

	public function new(?interfaces:Array<FfiInterfaceSource>, ?projections:Array<FfiProjectionSource>) {
		this.interfaces = interfaces == null
			? [] : HxiInterfaceOrder.dependenciesFirst([for (source in interfaces)
			{
				path:source.path,
					text:source.text
			}]);
		this.projections = projections == null ? [] : [for (source in projections) {
			path:source.path, text:source.text
		}];
	}

	public function interfaceSources():Array<FfiInterfaceSource>
		return [for (source in interfaces) {
			path:source.path, text:source.text
		}];

	public function projectionSources():Array<FfiProjectionSource>
		return [for (source in projections) {
			path:source.path, text:source.text
		}];
}

/** The declarations an interface takes from the interfaces it depends on. */
typedef FfiComposition = {
	final omitted:Map<String, Bool>;
	final declarations:Map<String, HxiDeclaration>;
}

/**
 * The FFI interfaces (HXI) and Haxe projection profiles a compiler was given, with what is derived from them: compositions, ABIs,
 * the projected Haxe modules and where their declarations come from. Each projected module is handed to `projected`, which the
 * compiler turns into a source update; a projection with no source is handed over with empty text.
 */
class FfiRegistry {
	final interfaceSources:Array<FfiInterfaceSource> = [];
	final interfaceModels:Map<String, HxiInterface> = [];
	final projectionSources:Array<FfiProjectionSource> = [];
	final projectionProfiles:Map<String, HxiProjectionProfile> = [];
	final projectionPaths:Map<String, String> = [];
	final projectionCache:Map<String, Array<HxiProjectedModule>> = [];
	final sourceOrigins:Map<String, Map<String, SourceSpan>> = [];
	final compositionCache:Map<String, FfiComposition> = [];
	final abiCache:Map<String, HxiAbi> = [];
	final projected:(path:String, source:String) -> Void;

	public function new(projected:(path:String, source:String) -> Void)
		this.projected = projected;

	/** A registry with the same interfaces and projections, which hands projected modules to `projected`. */
	public function clone(projected:(path:String, source:String) -> Void):FfiRegistry {
		var result = new FfiRegistry(projected);
		for (source in interfaceSources)
			result.interfaceSources.push(source);
		for (name => model in interfaceModels)
			result.interfaceModels.set(name, model);
		for (source in projectionSources)
			result.projectionSources.push(source);
		for (name => profile in projectionProfiles)
			result.projectionProfiles.set(name, profile);
		for (name => path in projectionPaths)
			result.projectionPaths.set(name, path);
		for (name => projections in projectionCache)
			result.projectionCache.set(name, projections);
		for (path => origins in sourceOrigins)
			result.sourceOrigins.set(path, origins);
		for (name => composition in compositionCache)
			result.compositionCache.set(name, composition);
		for (name => abi in abiCache)
			result.abiCache.set(name, abi);
		return result;
	}

	/** Parse, validate and register one ABI interface, projecting it when its profile is already registered. */
	public function registerInterface(path:String, source:String):Void {
		var model = HxiParser.parse(path, source);
		if (interfaceModels.exists(model.name))
			throw 'FFI interface "${model.name}" is already registered';
		var dependencies:Array<HxiInterface> = [];
		for (dependencyName in model.dependencies) {
			var dependency = interfaceModels.get(dependencyName);
			if (dependency != null)
				dependencies.push(dependency);
		}
		HxiValidator.validateComposition(model, dependencies);
		var composition = buildComposition(model),
			profile = projectionProfiles.get(model.name);
		if (profile != null)
			HxiProjection.validateProfile(projectionPaths.get(model.name), model, composition.omitted,
				composition.declarations, profile);
		interfaceModels.set(model.name, model);
		interfaceSources.push({path: path, text: source});
		compositionCache.set(model.name, composition);
		refreshProjection(model);
	}

	/** Register the Haxe-only naming policy of one interface, projecting it again when the interface is registered. */
	public function registerProjection(path:String, source:String):Void {
		var profile = HxiProjectionProfile.parse(path, source),
			name = profile.interfaceName;
		if (name == null)
			throw 'FFI projection "$path" does not name an interface';
		if (projectionProfiles.exists(name))
			throw 'FFI projection for interface "$name" is already registered';
		var model = interfaceModels.get(name);
		if (model != null) {
			var composition = compositionOf(model);
			HxiProjection.validateProfile(path, model, composition.omitted, composition.declarations, profile);
		}
		projectionProfiles.set(name, profile);
		projectionPaths.set(name, path);
		projectionSources.push({path: path, text: source});
		if (model != null) {
			projectionCache.remove(name);
			refreshProjection(model);
		}
	}

	/** Validated ABI interfaces in deterministic interface-name order. */
	public function interfaces():Array<HxiInterface> {
		var names = [for (name in interfaceModels.keys()) name];
		names.sort(Reflect.compare);
		return [for (name in names) interfaceModels.get(name)];
	}

	/** The C natives of every interface, in interface-name order. */
	public function cNatives():Array<IrCNative> {
		for (name in sortedProjectionNames())
			if (!interfaceModels.exists(name))
				throw 'FFI projection "${projectionPaths.get(name)}" names unknown interface "$name"';
		var result:Array<IrCNative> = [];
		for (model in interfaces()) {
			var composition = compositionOf(model);
			for (native in HxiProjection.cNatives(model, composition.omitted, composition.declarations,
				abiOf(model, composition),
				projectionProfiles.get(model.name)))
				result.push(native);
		}
		return result;
	}

	/** Resolve generated declarations and their helper members to the owning ABI source. */
	public function sourceOrigin(path:String, name:String):Null<SourceSpan> {
		var origins = sourceOrigins.get(path);
		if (origins == null)
			return null;
		var candidate = name;
		while (candidate.length > 0) {
			var origin = origins.get(candidate);
			if (origin != null)
				return origin;
			var dot = candidate.indexOf(".");
			if (dot < 0)
				break;
			candidate = candidate.substr(dot + 1);
		}
		// Synthesized methods such as SurfaceHandle.invalid() belong to their type.
		var member = name.lastIndexOf(".");
		return member < 0 ? null : sourceOrigin(path, name.substr(0, member));
	}

	function refreshProjection(model:HxiInterface):Void {
		var projections = projectionCache.get(model.name);
		if (projections == null) {
			var composition = compositionOf(model);
			projections = HxiProjection.modules(model, composition.omitted, composition.declarations,
				abiOf(model, composition),
				projectionProfiles.get(model.name));
			projectionCache.set(model.name, projections);
		}
		for (projection in projections) {
			if (projection.source.length > 0)
				sourceOrigins.set(projection.path + ".hx", projection.origins);
			projected(projection.path + ".hx", projection.source);
		}
	}

	function abiOf(model:HxiInterface, composition:FfiComposition):HxiAbi {
		var abi = abiCache.get(model.name);
		if (abi == null) {
			abi = HxiAbi.forInterface(model, composition.declarations);
			abiCache.set(model.name, abi);
		}
		return abi;
	}

	function compositionOf(model:HxiInterface):FfiComposition {
		var cached = compositionCache.get(model.name);
		if (cached != null)
			return cached;
		var result = buildComposition(model);
		compositionCache.set(model.name, result);
		return result;
	}

	function buildComposition(model:HxiInterface):FfiComposition {
		// Imported HXI files can repeat declarations from included headers. Keep
		// those snapshots available for ABI classification, but emit each shared
		// declaration and native symbol from its owning interface only.
		var omitted:Map<String, Bool> = [],
			declarations:Map<String, HxiDeclaration> = [],
			visited:Map<String, Bool> = [],
			active:Map<String, Bool> = [];
		for (dependency in model.dependencies)
			collectDependency(model.name, dependency, omitted, declarations, visited, active);
		return {omitted: omitted, declarations: declarations};
	}

	function sortedProjectionNames():Array<String> {
		var names = [for (name in projectionProfiles.keys()) name];
		names.sort(Reflect.compare);
		return names;
	}

	function collectDependency(owner:String, name:String, omitted:Map<String, Bool>,
			declarations:Map<String, HxiDeclaration>, visited:Map<String, Bool>,
			active:Map<String, Bool>):Void {
		if (active.get(name) == true)
			throw 'Cyclic HXI dependency involving "$owner" and "$name"';
		if (visited.get(name) == true)
			return;
		var dependency = interfaceModels.get(name);
		if (dependency == null)
			throw 'FFI interface "$owner" depends on unknown interface "$name"';
		active.set(name, true);
		for (nested in dependency.dependencies)
			collectDependency(owner, nested, omitted, declarations, visited, active);
		active.remove(name);
		visited.set(name, true);
		for (declaration in dependency.declarations) {
			var declarationName = declarationNameOf(declaration);
			omitted.set(declarationName, true);
			if (!declarations.exists(declarationName))
				declarations.set(declarationName, declaration);
		}
	}

	static function declarationNameOf(declaration:HxiDeclaration):String
		return switch declaration {
			case Opaque(name, _) | Alias(name, _, _) | Handle(name, _, _, _) | Constant(name, _, _) | Structure(name, _,
				_, _, _) | Enumeration(name, _, _, _, _) | Callback(name, _, _, _, _) | Function(name, _, _, _, _, _, _,
				_): name;
		};
}
