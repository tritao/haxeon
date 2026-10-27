package haxeon.platform.internal.event;

import haxeon.platform.event.PlatformEvent;
import haxeon.platform.internal.event.EventBytes;
import haxeon.platform.internal.event.EventSnapshot;
import nativekit.ffi.NativeKitTypes.EventKind;
import nativekit.ffi.NativeKitTypes.SurfaceResizeEvent;
import nativekit.ffi.NativeKitTypes.WindowFramebufferResizeEvent;
import nativekit.ffi.NativeKitTypes.WindowMoveEvent;
import nativekit.ffi.NativeKitTypes.WindowResizeEvent;
import nativekit.ffi.NativeKitTypes.WindowScaleEvent;
import nativekit.ffi.NativeKitTypes.WindowState;

class WindowEventDecoder {
	public static function decode(c:EventSnapshot):Null<PlatformEvent> {
		return switch c.kind {
			case EventKind.WindowClose: WindowClose(c.source);
			case EventKind.WindowResize:
				EventBytes.requireSize(c.data, 8); var v:WindowResizeEvent = c.data; WindowResize(c.source, v.get_width(), v.get_height());
			case EventKind.WindowMove:
				EventBytes.requireSize(c.data, 8); var v:WindowMoveEvent = c.data; WindowMove(c.source, v.get_x(), v.get_y());
			case EventKind.WindowFramebufferResize:
				EventBytes.requireSize(c.data, 8); var v:WindowFramebufferResizeEvent = c.data; WindowFramebufferResize(c.source, v.get_width(), v.get_height());
			case EventKind.WindowScaleChanged:
				EventBytes.requireSize(c.data, 4); var v:WindowScaleEvent = c.data; WindowScaleChanged(c.source, v.get_scale());
			case EventKind.WindowStateChanged:
				EventBytes.requireSize(c.data, 24); var v:WindowState = c.data; WindowStateChanged(c.source, v.get_flags());
			case EventKind.SurfaceReady: SurfaceReady(c.source);
			case EventKind.SurfaceResize:
				EventBytes.requireSize(c.data, 16); var v:SurfaceResizeEvent = c.data; SurfaceResize(c.source, v.get_width(), v.get_height(), v.get_framebuffer_width(), v.get_framebuffer_height());
			case EventKind.SurfaceLost: SurfaceLost(c.source);
			default: null;
		}
	}
}
