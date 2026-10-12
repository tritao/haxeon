package haxeon.animation.rig;

/**
 * Names of an asset rig's joints for each standard bone. Joint names are
 * compared after dropping any namespace prefix ending in ':', so Mixamo's
 * "mixamorig:Hips" and "mixamorig1:Hips" both match "Hips". A bone may list
 * alternatives, used in order, for variants within one rig family.
 */
class RigMapping {
	public final name:String;
	final joints:Map<String, String>;
	final alternatives:Map<String, Array<String>> = new Map();

	public function new(name:String, joints:Map<String, String>) {
		this.name = name;
		this.joints = joints;
	}

	/** The asset joint names that may provide a standard bone, preferred first. */
	public function jointNames(bone:HumanBone):Array<String> {
		var primary = joints.get(bone);
		var names:Array<String> = primary == null ? [] : [primary];
		var others = alternatives.get(bone);
		return others == null ? names : names.concat(others);
	}

	/** Adds a fallback joint name for a bone, tried after the ones already given. */
	public function alternative(bone:HumanBone, joint:String):RigMapping {
		var others = alternatives.get(bone);
		if (others == null)
			alternatives.set(bone, [joint]);
		else
			others.push(joint);
		return this;
	}

	/** Quaternius characters, including the Ultimate Modular and Universal Animation rigs. */
	public static function quaternius():RigMapping {
		var joints:Map<String, String> = [
			HumanBone.Pelvis => "Hips", HumanBone.Spine => "Abdomen", HumanBone.Spine2 => "Torso",
			HumanBone.Chest => "Chest", HumanBone.Neck => "Neck", HumanBone.Head => "Head"
		];
		for (side in ["L", "R"]) {
			joints.set('shoulder.$side', 'Shoulder.$side');
			joints.set('upper_arm.$side', 'UpperArm.$side');
			joints.set('forearm.$side', 'LowerArm.$side');
			joints.set('hand.$side', 'Wrist.$side');
			// Quaternius's *1 finger joints share one pivot inside the palm; the
			// knuckles the standard bones describe are the *2 joints.
			joints.set('index1.$side', 'Index2.$side');
			joints.set('middle1.$side', 'Middle2.$side');
			joints.set('pinky1.$side', 'Pinky2.$side');
			joints.set('thigh.$side', 'UpperLeg.$side');
			joints.set('shin.$side', 'LowerLeg.$side');
			joints.set('foot.$side', 'Foot.$side');
			joints.set('toe.$side', 'Toes.$side');
			// Blender exports each chain's bone tail as a "_end" leaf.
			joints.set('toe_tip.$side', 'Toes.${side}_end');
		}
		var mapping = new RigMapping("quaternius", joints);
		// Rigs without toe bones end the foot bone at the toe tips.
		mapping.alternative(HumanBone.ToeTipL, "Foot.L_end").alternative(HumanBone.ToeTipR, "Foot.R_end");
		return mapping;
	}

	/** Quaternius's Universal Animation Library character, whose joints are Blender "DEF-" deformation bones. */
	public static function universal():RigMapping {
		var joints:Map<String, String> = [
			HumanBone.Pelvis => "DEF-hips", HumanBone.Spine => "DEF-spine.001", HumanBone.Spine2 => "DEF-spine.002",
			HumanBone.Chest => "DEF-spine.003", HumanBone.Neck => "DEF-neck", HumanBone.Head => "DEF-head"
		];
		for (side in ["L", "R"]) {
			joints.set('shoulder.$side', 'DEF-shoulder.$side');
			joints.set('upper_arm.$side', 'DEF-upper_arm.$side');
			joints.set('forearm.$side', 'DEF-forearm.$side');
			joints.set('hand.$side', 'DEF-hand.$side');
			joints.set('index1.$side', 'DEF-f_index.01.$side');
			joints.set('middle1.$side', 'DEF-f_middle.01.$side');
			joints.set('pinky1.$side', 'DEF-f_pinky.01.$side');
			joints.set('thigh.$side', 'DEF-thigh.$side');
			joints.set('shin.$side', 'DEF-shin.$side');
			joints.set('foot.$side', 'DEF-foot.$side');
			joints.set('toe.$side', 'DEF-toe.$side');
		}
		return new RigMapping("universal", joints);
	}

	/** Mixamo exports, with or without the "mixamorig:" namespace. */
	public static function mixamo():RigMapping {
		var joints:Map<String, String> = [
			HumanBone.Pelvis => "Hips", HumanBone.Spine => "Spine", HumanBone.Spine2 => "Spine1",
			HumanBone.Chest => "Spine2", HumanBone.Neck => "Neck", HumanBone.Head => "Head"
		];
		for (pair in [["L", "Left"], ["R", "Right"]]) {
			var side = pair[0], prefix = pair[1];
			joints.set('shoulder.$side', '${prefix}Shoulder');
			joints.set('upper_arm.$side', '${prefix}Arm');
			joints.set('forearm.$side', '${prefix}ForeArm');
			joints.set('hand.$side', '${prefix}Hand');
			joints.set('index1.$side', '${prefix}HandIndex1');
			joints.set('middle1.$side', '${prefix}HandMiddle1');
			joints.set('pinky1.$side', '${prefix}HandPinky1');
			joints.set('thigh.$side', '${prefix}UpLeg');
			joints.set('shin.$side', '${prefix}Leg');
			joints.set('foot.$side', '${prefix}Foot');
			joints.set('toe.$side', '${prefix}ToeBase');
			joints.set('toe_tip.$side', '${prefix}Toe_End');
		}
		return new RigMapping("mixamo", joints);
	}

	public static function presets():Array<RigMapping>
		return [quaternius(), mixamo(), universal()];

	/** Drops a namespace prefix such as "mixamorig:". */
	public static function localName(joint:String):String
		return joint.substr(joint.lastIndexOf(":") + 1);
}
