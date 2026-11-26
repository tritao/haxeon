package haxeon.gpu;

import haxeon.platform.BindingError;

import haxeon.gpu.AttachmentAction;
import haxeon.gpu.Image;

import haxeon.gpu.Renderer;

import nativekit.ffi.NativeKitGpu;

/** One color attachment and its optional MSAA resolve image. */
class ColorAttachment {
	/** The image drawn into. */
	public final image:Image;

	/** Where a multisampled image is resolved to, or null. */
	public var resolveImage:Null<Image>;

	/** How the pass loads and stores it. */
	public var action:AttachmentAction;

	/** An attachment drawing into `image`. */
	public function new(image:Image, action:AttachmentAction,
			resolveImage:Null<Image> = null) {
		this.image = image;
		this.action = action;
		this.resolveImage = resolveImage;
	}
}

/** Portable render-pass attachment description. */
class RenderPassDesc {
	/** The colour attachments, in output order. */
	public var colors:Array<ColorAttachment>;

	/** The depth-stencil image, or null. */
	public var depthStencil:Null<Image>;

	/** How the pass loads and stores it. */
	public var depthStencilAction:AttachmentAction;

	/** A pass with no attachments yet. */
	public function new() {
		colors = [];
		depthStencil = null;
		depthStencilAction = new AttachmentAction();
	}

	/** Adds a colour attachment. Returns this description. */
	public function color(image:Image, action:AttachmentAction,
			resolveImage:Null<Image> = null):RenderPassDesc {
		if (colors.length >= 4)
			throw BindingError.invalidArgument("RenderPassDesc.color",
				"GPU render passes support at most four color attachments");
		colors.push(new ColorAttachment(image, action, resolveImage));
		return this;
	}

	/** Sets the depth-stencil attachment, loading and storing by default. Returns this description. */
	public function depth(image:Image, action:AttachmentAction = null):RenderPassDesc {
		depthStencil = image;
		depthStencilAction = action == null ? new AttachmentAction() : action;
		return this;
	}

	@:allow(haxeon.gpu.Renderer)
	@:allow(haxeon.gpu.Batch)
	function nativeValue():nkgpu_render_pass_desc {
		var value = new nkgpu_render_pass_desc();
		value.struct_size = nkgpu_render_pass_desc.byteSize();
		value.color_count = colors.length;
		for (index in 0...colors.length) {
			var source = colors[index];
			var attachment = new nkgpu_color_attachment();
			attachment.image = source.image.nativeHandle();
			attachment.resolve_image = source.resolveImage == null
				? nkgpu_image.invalid() : source.resolveImage.nativeHandle();
			attachment.set_action(source.action.nativeValue());
			value.set_colors(index, attachment);
		}
		if (depthStencil != null) {
			value.depth_stencil = depthStencil.nativeHandle();
			value.set_depth_stencil_action(depthStencilAction.nativeValue());
		}
		return value;
	}
}
