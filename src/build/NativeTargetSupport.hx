package build;

import project.ResolvedProject;

/** Validates native provider capabilities before any compiler or linker runs. */
class NativeTargetSupport {
	public static function validate(project:ResolvedProject, target:Target):Void {
		for (resolvedPackage in project.packages.packages) {
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
