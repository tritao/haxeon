package haxeon.ui;

import NativeKitUI;
import haxeon.ui.core.UiFrameMetrics;

/** Typed retained display list. Resources referenced by the list stay alive natively until it is cleared or replaced. */
class DisplayList implements Disposable {
	var value:nkui_display_list;
	var disposed:Bool;

	private function new(value:nkui_display_list) {
		this.value = value;
		disposed = false;
	}

	/** An empty display list. */
	public static function create():DisplayList {
		var made = NativeKitUI.nkui_display_list_create();
		UiResult.check(made.status, "displayList.create");
		return new DisplayList(made.out_list);
	}

	/** Replaces this list with the command stream encoded by canvas. */
	public function update(canvas:Canvas):Void {
		ensureLive();
		var started = RenderCost.time();
		canvas.submitTo(value);
		if (RenderCost.enabled) RenderCost.encode += Sys.time() - started;
	}

	/** Removes all commands and releases the list's retained resource references. */
	public function clear():Void {
		ensureLive();
		UiResult.check(NativeKitUI.nkui_display_list_reset(value), "displayList.clear");
	}

	/** Its size and command count. */
	public function info():DisplayListInfo {
		ensureLive();
		var result = NativeKitUI.nkui_display_list_get_info(value);
		UiResult.check(result.status, "displayList.info");
		return new DisplayListInfo(result.out_info.get_command_bytes(), result.out_info.get_command_count(),
			result.out_info.get_api_version());
	}

	/** Releases this list. Repeated disposal is safe. */
	public function dispose():Void {
		if (disposed)
			return;
		var status = NativeKitUI.nkui_display_list_destroy(value);
		disposed = true;
		UiResult.check(status, "displayList.dispose");
	}

	/** Whether it was disposed. */
	public function isDisposed():Bool
		return disposed;

	@:allow(haxeon.ui.Renderer)
	@:allow(haxeon.ui.Canvas)
	@:allow(haxeon.ui.LayoutSession)
	private function nativeHandle():nkui_display_list {
		ensureLive();
		return value;
	}

	function ensureLive():Void {
		if (disposed)
			throw "Display list has been disposed";
	}
}

/** Stable summary of a retained display list. */
class DisplayListInfo {
	/** How many bytes its commands take. */
	public final commandBytes:Int;

	/** How many commands it holds. */
	public final commandCount:Int;

	/** The command encoding's version, as the native renderer reads it. */
	public final apiVersion:Int;

	/** A display list's size and command count. */
	public function new(commandBytes:Int, commandCount:Int, apiVersion:Int) {
		this.commandBytes = commandBytes;
		this.commandCount = commandCount;
		this.apiVersion = apiVersion;
	}
}
