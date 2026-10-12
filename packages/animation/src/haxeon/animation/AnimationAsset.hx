package haxeon.animation;

import AnimKitNative;
import haxe.io.Bytes;

/** One drawable mesh primitive of an imported asset. */
typedef AssetPrimitive = {
	var name:String;
	var vertexCount:Int;
	var indexCount:Int;
	/** Material index, or -1 for the default material. */
	var material:Int;
	var skinned:Bool;
	var hasTexcoords:Bool;
	/** Joint a rigid primitive follows, or -1 when skinned. */
	var joint:Int;
}

/** glTF metallic-roughness material values AnimKit imports. */
typedef AssetMaterial = {
	var name:String;
	var baseColor:Array<Float>;
	var metallic:Float;
	var roughness:Float;
	var emissive:Array<Float>;
	/** 1 opaque, 2 mask, 3 blend, matching SceneKit's alpha modes. */
	var alphaMode:Int;
	var alphaCutoff:Float;
	var doubleSided:Bool;
	/** Decoded image index, or -1. */
	var baseColorImage:Int;
}

/**
 * An imported glTF asset: skeleton, meshes, materials, decoded images, and
 * animation clips. Outputs are in model space (+Z up, +X forward, metres).
 * Every node of the glTF scene is a joint, so names match the source nodes.
 */
class AnimationAsset {
	public final jointNames:Array<String> = [];
	/** Parent joint per joint, or -1 for roots; parents precede children. */
	public final jointParents:Array<Int> = [];
	public final clipNames:Array<String> = [];
	public final clipDurations:Array<Float> = [];
	public final primitives:Array<AssetPrimitive> = [];
	public final materials:Array<AssetMaterial> = [];
	public final imageCount:Int;
	/** Non-fatal import diagnostics, such as unsupported features that were skipped. */
	public final warnings:Array<String> = [];

	final owner:Ownedak_asset_handle;
	var disposed:Bool = false;

	/** Loads a .gltf or .glb file; relative buffers and images resolve beside it. */
	public static function load(path:String):AnimationAsset {
		var loaded = AnimKitNative.ak_asset_load_file(path);
		if (loaded.status != AnimKitNativeConstants.AK_OK)
			throw 'Failed to load glTF asset "$path": ${AnimKitNative.ak_last_error()}';
		return new AnimationAsset(loaded.out_asset);
	}

	/** Loads a GLB, or a .gltf whose buffers and images are embedded data URIs. */
	public static function fromBytes(data:Bytes):AnimationAsset {
		var loaded = AnimKitNative.ak_asset_load_memory_slice(data, 0, data.length);
		if (loaded.status != AnimKitNativeConstants.AK_OK)
			throw 'Failed to load glTF asset: ${AnimKitNative.ak_last_error()}';
		return new AnimationAsset(loaded.out_asset);
	}

	function new(owner:Ownedak_asset_handle) {
		this.owner = owner;
		var handle = owner.borrow();
		var info = new ak_asset_info();
		info.set_struct_size(ak_asset_info.size());
		check(AnimKitNative.ak_asset_get_info(handle, info), "asset.info");
		imageCount = info.get_image_count();
		for (joint in 0...info.get_joint_count()) {
			jointNames.push(AnimKitNative.ak_asset_joint_name(handle, joint));
			jointParents.push(AnimKitNative.ak_asset_joint_parent(handle, joint));
		}
		for (clip in 0...info.get_clip_count()) {
			clipNames.push(AnimKitNative.ak_asset_clip_name(handle, clip));
			clipDurations.push(AnimKitNative.ak_asset_clip_duration(handle, clip));
		}
		for (index in 0...info.get_primitive_count()) {
			var value = new ak_primitive_info();
			value.set_struct_size(ak_primitive_info.size());
			check(AnimKitNative.ak_asset_get_primitive(handle, index, value), "asset.primitive");
			primitives.push({
				name: AnimKitNative.ak_asset_primitive_name(handle, index),
				vertexCount: value.get_vertex_count(),
				indexCount: value.get_index_count(),
				material: value.get_material(),
				skinned: value.get_skinned() != 0,
				hasTexcoords: value.get_has_texcoords() != 0,
				joint: value.get_joint()
			});
		}
		for (index in 0...info.get_material_count()) {
			var value = new ak_material_info();
			value.set_struct_size(ak_material_info.size());
			check(AnimKitNative.ak_asset_get_material(handle, index, value), "asset.material");
			materials.push({
				name: AnimKitNative.ak_asset_material_name(handle, index),
				baseColor: [for (i in 0...4) value.get_base_color(i)],
				metallic: value.get_metallic(),
				roughness: value.get_roughness(),
				emissive: [for (i in 0...3) value.get_emissive(i)],
				alphaMode: value.get_alpha_mode(),
				alphaCutoff: value.get_alpha_cutoff(),
				doubleSided: value.get_double_sided() != 0,
				baseColorImage: value.get_base_color_image()
			});
		}
		for (index in 0...info.get_warning_count())
			warnings.push(AnimKitNative.ak_asset_warning(handle, index));
	}

	/** Returns the joint with this glTF node name, or -1. */
	public function jointIndex(name:String):Int {
		for (index in 0...jointNames.length)
			if (jointNames[index] == name)
				return index;
		return -1;
	}

	/**
	 * Returns the clip with this exact name, or else the clip whose action name
	 * matches ignoring case, or -1. Blender exports clips as "Armature|Action",
	 * so "walk" finds "CharacterArmature|Walk".
	 */
	public function clipIndex(name:String):Int {
		for (index in 0...clipNames.length)
			if (clipNames[index] == name)
				return index;
		var wanted = name.toLowerCase();
		for (index in 0...clipNames.length) {
			var clip = clipNames[index];
			if (clip.substr(clip.lastIndexOf("|") + 1).toLowerCase() == wanted)
				return index;
		}
		// Some libraries name a looping clip with a "_Loop" suffix: "walk" finds "Walk_Loop".
		for (index in 0...clipNames.length) {
			var clip = clipNames[index];
			if (clip.substr(clip.lastIndexOf("|") + 1).toLowerCase() == wanted + "_loop")
				return index;
		}
		return -1;
	}

	/** Packed uint32 triangle indices. */
	public function readIndices(primitive:Int):Bytes {
		var read = AnimKitNative.ak_asset_read_indices(handle(), primitive);
		check(read.status, "asset.indices");
		return read.data;
	}

	/** Packed float32 UV pairs with glTF's top-left origin, or null when absent. */
	public function readTexcoords(primitive:Int):Null<Bytes> {
		var read = AnimKitNative.ak_asset_read_texcoords(handle(), primitive);
		check(read.status, "asset.texcoords");
		return read.data.length == 0 ? null : read.data;
	}

	/** Float32 xyz positions in source bind space. */
	public function readBindPositions(primitive:Int):Bytes {
		var read = AnimKitNative.ak_asset_read_bind_positions(handle(), primitive);
		check(read.status, "asset.bind_positions");
		return read.data;
	}

	/** Float32 xyz normals in source bind space. */
	public function readBindNormals(primitive:Int):Bytes {
		var read = AnimKitNative.ak_asset_read_bind_normals(handle(), primitive);
		check(read.status, "asset.bind_normals");
		return read.data;
	}

	/** Uint16x4 palette indices per vertex; empty for rigid primitives. */
	public function readJointIndices(primitive:Int):Bytes {
		var read = AnimKitNative.ak_asset_read_joint_indices(handle(), primitive);
		check(read.status, "asset.joint_indices");
		return read.data;
	}

	/** Float32x4 weights per vertex; empty for rigid primitives. */
	public function readJointWeights(primitive:Int):Bytes {
		var read = AnimKitNative.ak_asset_read_joint_weights(handle(), primitive);
		check(read.status, "asset.joint_weights");
		return read.data;
	}

	/** Int32 skeleton joints in palette order; owning joint for rigid primitives. */
	public function readSkinJoints(primitive:Int):Bytes {
		var read = AnimKitNative.ak_asset_read_skin_joints(handle(), primitive);
		check(read.status, "asset.skin_joints");
		return read.data;
	}

	/** Column-major float32 4x4 inverse binds in palette order. */
	public function readInverseBindMatrices(primitive:Int):Bytes {
		var read = AnimKitNative.ak_asset_read_inverse_bind_matrices(handle(), primitive);
		check(read.status, "asset.inverse_bind_matrices");
		return read.data;
	}

	public function imageWidth(image:Int):Int
		return imageInfo(image).get_width();

	public function imageHeight(image:Int):Int
		return imageInfo(image).get_height();

	/** Decoded RGBA8 pixels, top row first. */
	public function readImage(image:Int):Bytes {
		var read = AnimKitNative.ak_asset_read_image(handle(), image);
		check(read.status, "asset.image");
		return read.data;
	}

	@:allow(haxeon.animation.AnimationInstance)
	function handle():ak_asset_handle {
		if (disposed)
			throw "Animation asset has been disposed";
		return owner.borrow();
	}

	/** Releases the asset; instances created from it stay valid. */
	public function dispose():Void {
		if (disposed)
			return;
		disposed = true;
		owner.close();
	}

	function imageInfo(image:Int):ak_image_info {
		var info = new ak_image_info();
		info.set_struct_size(ak_image_info.size());
		check(AnimKitNative.ak_asset_get_image(handle(), image, info), "asset.image");
		return info;
	}

	@:allow(haxeon.animation.AnimationInstance)
	static function check(status:Int, operation:String):Void {
		if (status != AnimKitNativeConstants.AK_OK)
			throw 'AnimKit $operation failed with status $status';
	}
}
