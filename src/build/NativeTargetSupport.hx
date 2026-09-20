package build;

import project.ResolvedProject;

/** Validates native provider capabilities before any compiler or linker runs. */
class NativeTargetSupport {
	public static function validate(project:ResolvedProject, target:Target):Void {
		for (resolvedPackage in project.packages.packages) {
			if (resolvedPackage.ffiImports.length > 0 && !target.isNative())
				throw 'Package ${resolvedPackage.name} declares FFI imports, but target "${target.toString()}" is not a native target';
			for (ffi in resolvedPackage.ffiImports)
				if (ffi.config.cxxThunks
					&& (resolvedPackage.manifest.native == null
						|| (resolvedPackage.manifest.native.cmake == null && resolvedPackage.nativeSources.length == 0)))
					throw 'Package ${resolvedPackage.name} FFI import "${ffi.config.name}" enables cxxThunks, but generated C++ thunks require native.sources or native.cmake';
			var native = resolvedPackage.manifest.native;
			if (native == null)
				continue;
			var supported = false;
			for (supportedTarget in native.supportedTargets)
				try {
					if (Target.parse(supportedTarget).equals(target))
						supported = true;
				} catch (_:Dynamic) {
					// PackageManifest validates these values; keep this check defensive.
				}
			if (!supported)
				throw 'Package ${resolvedPackage.name} cannot be built for ${target.toString()}:\n'
					+ '  ${resolvedPackage.name} -> native dependency ${resolvedPackage.name}\n'
					+ '  no ${target.toString()} provider is available';
		}
	}
}
