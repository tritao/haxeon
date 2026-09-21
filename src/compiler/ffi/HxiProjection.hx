package compiler.ffi;

import compiler.ffi.HxiAbi.HxiAbi;
import compiler.ffi.HxiModel.HxiDeclaration;
import compiler.ffi.HxiModel.HxiInterface;
import compiler.ffi.HxiProjectionProfile;
import compiler.ir.Ir.IrCNative;
import compiler.ffi.HxiProjectedModule;

/** Public entry points for HXI projection planning and emission. */
class HxiProjection {
	public static function validateProfile(path:String, model:HxiInterface, ?omitted:Map<String, Bool>, ?visibleDeclarations:Map<String, HxiDeclaration>,
			profile:HxiProjectionProfile):Void
		HxiProjectionProfileValidator.validate(path, model, omitted, visibleDeclarations, profile);

	public static function plan(path:String, model:HxiInterface, ?omitted:Map<String, Bool>, ?visibleDeclarations:Map<String, HxiDeclaration>,
			?providedAbi:HxiAbi, ?profile:HxiProjectionProfile):HaxeProjectionModel
		return HxiProjectionPlanner.plan(path, model, omitted, visibleDeclarations, providedAbi, profile);

	public static function cNatives(model:HxiInterface, ?omitted:Map<String, Bool>, ?visibleDeclarations:Map<String, HxiDeclaration>, ?providedAbi:HxiAbi,
			?profile:HxiProjectionProfile):Array<IrCNative>
		return HxiHaxeEmitter.cNatives(model, omitted, visibleDeclarations, providedAbi, profile);

	public static function source(model:HxiInterface, ?omitted:Map<String, Bool>, ?visibleDeclarations:Map<String, HxiDeclaration>, ?providedAbi:HxiAbi,
			?profile:HxiProjectionProfile):String {
		if (model.library == null)
			return "";
		var path = model.name + ".hxmap",
			planned = HxiProjectionPlanner.plan(path, model, omitted, visibleDeclarations, providedAbi, profile);
		return HxiHaxeEmitter.emit(planned);
	}

	/** Emit the projection as one or more Haxe modules according to its profile. */
	public static function modules(model:HxiInterface, ?omitted:Map<String, Bool>, ?visibleDeclarations:Map<String, HxiDeclaration>, ?providedAbi:HxiAbi,
			?profile:HxiProjectionProfile):Array<HxiProjectedModule> {
		if (model.library == null)
			return [];
		var path = model.name + ".hxmap",
			planned = HxiProjectionPlanner.plan(path, model, omitted, visibleDeclarations, providedAbi, profile);
		return HxiHaxeEmitter.emitModules(planned);
	}
}
