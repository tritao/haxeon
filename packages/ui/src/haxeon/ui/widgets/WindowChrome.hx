package haxeon.ui.widgets;
import haxeon.ui.core.ViewRoot;

import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import nativekit.ffi.NativeKitTypes.WindowDecorationRegionKind;

/**
	Annotates a view with native window-chrome behavior after it has been built.
	Child regions are emitted after their parent, allowing client controls to
	carve interactive holes out of a larger drag region.
*/
class WindowChrome implements View {
	final key:haxeon.ui.core.Key;
	final child:View;
	final kind:WindowDecorationRegionKind;
	final cursor:Null<CursorShape>;

	/** Marks `child` as a window region of `kind`, such as a drag area or a resize edge, showing `cursor` over it. */
	public function new(key:String, kind:WindowDecorationRegionKind, child:View,
			?cursor:CursorShape) {
		if (key == null || key.length == 0 || kind == null || child == null)
			throw "Window chrome views require a key, kind, and child";
		this.key = new haxeon.ui.core.Key(key);
		this.kind = kind;
		this.child = child;
		this.cursor = cursor;
	}

	public function build(context:BuildContext):ViewRoot {
		var modifier = new haxeon.ui.core.RootModifier();
		modifier.windowDecoration = kind;
		modifier.windowDecorationCursor = cursor;
		return context.withScope(key, function() return context.build(child, modifier));
	}
}
