package haxeon.gpu;

import haxeon.gpu.Enums;
import haxeon.gpu.RenderPassDesc;

import haxeon.gpu.Enums.LoadAction;
import haxeon.gpu.Enums.StoreAction;
import nativekit.ffi.NativeKitGpu;

/** Clear and store behavior for one render-pass attachment. */
class AttachmentAction {
	/** What the pass starts the attachment with: its contents, a clear, or nothing defined. */
	public var loadAction:LoadAction;

	/** Whether the pass keeps what it drew. */
	public var storeAction:StoreAction;

	/** The clear colour's red, from 0 to 1. */
	public var clearRed:Float;

	/** Its green. */
	public var clearGreen:Float;

	/** Its blue. */
	public var clearBlue:Float;

	/** Its alpha. */
	public var clearAlpha:Float;

	/** The depth a clear writes. */
	public var clearDepth:Float;

	/** The stencil value a clear writes. */
	public var clearStencil:Int;

	/** An action that loads and stores by default. */
	public function new(loadAction:LoadAction = LoadAction.Load,
			storeAction:StoreAction = StoreAction.Store) {
		this.loadAction = loadAction;
		this.storeAction = storeAction;
		clearRed = 0.0;
		clearGreen = 0.0;
		clearBlue = 0.0;
		clearAlpha = 0.0;
		clearDepth = 1.0;
		clearStencil = 0;
	}

	@:allow(haxeon.gpu.RenderPassDesc)
	function nativeValue():nkgpu_attachment_action {
		var value = new nkgpu_attachment_action();
		value.set_load_action(loadAction);
		value.set_store_action(storeAction);
		var color = new nkgpu_color();
		color.set_r(clearRed);
		color.set_g(clearGreen);
		color.set_b(clearBlue);
		color.set_a(clearAlpha);
		value.set_clear_color(color);
		value.set_clear_depth(clearDepth);
		value.set_clear_stencil(clearStencil);
		return value;
	}
}
