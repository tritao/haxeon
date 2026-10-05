import nativekit.ffi.NativeKitTypes;
import nativekit.ffi.NativeKit;
import NativeKitUI;
import GraphicsImageRef;

/** Typed compositable surface produced by NativeKit's renderer. */
class GraphicsSurface extends NativeKitUIResource {
	@:allow(ShowcaseCube)
	private function new(value:nkui_resource)
		super(value);

	/** Imports a sampled image/target produced by Graphics. */
	public static function fromGraphicsImage(image:GraphicsImage):GraphicsSurface {
		return fromHandle(image);
	}

	/** Imports a retained backend-neutral image produced by Graphics. */
	public static function fromImage(image:GraphicsImageRef):GraphicsSurface {
		if (image == null)
			throw "graphicsSurface.fromImage requires an image";
		return fromHandle(image.nativeHandle());
	}

	static function fromHandle(image:GraphicsImage):GraphicsSurface {
		var made = NativeKitUI.nkui_graphics_surface_create(image);
		UiResult.check(made.status, "graphicsSurface.fromGraphicsImage");
		return new GraphicsSurface(made.out_surface);
	}
}
