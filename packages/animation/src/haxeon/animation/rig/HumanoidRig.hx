package haxeon.animation.rig;

import haxeon.animation.AnimationAsset;

/** An asset's joints resolved onto the standard humanoid bones. */
class HumanoidRig {
	/** How the asset's joint names were matched to standard bones. */
	public final mapping:RigMapping;
	final joints:Map<String, Int> = new Map();

	/** Resolves mapping against asset; throws when a required bone is missing. */
	public function new(asset:AnimationAsset, mapping:RigMapping) {
		this.mapping = mapping;
		var byLocalName:Map<String, Int> = new Map();
		for (index in 0...asset.jointNames.length) {
			var local = RigMapping.localName(asset.jointNames[index]);
			if (!byLocalName.exists(local))
				byLocalName.set(local, index);
		}
		var missing:Array<String> = [];
		for (bone in HumanBone.all()) {
			var joint:Null<Int> = null;
			for (name in mapping.jointNames(bone))
				if (joint == null)
					joint = byLocalName.get(name);
			if (joint != null)
				joints.set(bone.rawValue(), joint);
			else if (HumanBone.REQUIRED.indexOf(bone) >= 0)
				missing.push(bone.rawValue());
		}
		if (missing.length > 0)
			throw 'Rig "${mapping.name}" lacks humanoid bones: ${missing.join(", ")}';
	}

	/** Uses the first preset that provides every required bone. */
	public static function detect(asset:AnimationAsset):HumanoidRig {
		var errors:Array<String> = [];
		for (preset in RigMapping.presets()) {
			try {
				return new HumanoidRig(asset, preset);
			} catch (error:String) {
				errors.push(error);
			}
		}
		throw 'No humanoid rig preset matches this asset (${errors.join("; ")})';
	}

	/** The asset joint for a standard bone, or -1 when the rig lacks it. */
	public function joint(bone:HumanBone):Int {
		var found = joints.get(bone.rawValue());
		return found == null ? -1 : found;
	}

	/** Whether the asset provides `bone`. */
	public function has(bone:HumanBone):Bool
		return joints.exists(bone.rawValue());
}
