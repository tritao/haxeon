package haxeon.ui.host;

import haxeon.ui.FrameInfo;
import haxeon.ui.LayoutFrame;
import haxeon.ui.Renderer;
import haxeon.ui.Surface;
import haxeon.ui.core.UiContext;
import nativekit.ffi.NativeKitTypes.SurfaceHandle;

/** Reuses the layout frame and render target for every callback on one surface. */
class UiSurfaceFrame {
	public final layout:LayoutFrame;
	final dimensions:FrameInfo;
	final target:Surface;

	public function new(surface:SurfaceHandle, width:Int, height:Int) {
		layout = new LayoutFrame(width, height);
		dimensions = new FrameInfo(width, height, width, height, 1.0);
		target = Surface.fromNativeHandle(surface);
	}

	public function configure(width:Float, height:Float, framebufferWidth:Int, framebufferHeight:Int,
			scale:Float, deltaSeconds:Float):Void {
		layout.setViewport(width, height);
		layout.deltaSeconds = deltaSeconds;
		dimensions.set(width, height, framebufferWidth, framebufferHeight, scale);
	}

	public function prepare(renderer:Renderer):Int
		return renderer.prepare(target);

	public function render(context:UiContext, renderer:Renderer):Void
		context.render(renderer, target, dimensions);
}
