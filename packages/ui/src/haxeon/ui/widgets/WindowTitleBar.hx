package haxeon.ui.widgets;
import haxeon.ui.core.ViewRoot;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RootModifier;
import haxeon.ui.core.View;
import haxeon.ui.host.UiHostContext;
import haxeon.ui.icons.IconName;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.layout.SizedBox;
import nativekit.ffi.NativeKitTypes.WindowDecorationRegionKind;

/**
 * A native drag surface with accessible window controls, which are client regions. An interactive view in `content` is part of
 * the drag surface unless it is wrapped in a client `WindowChrome`.
 */
class WindowTitleBar implements View {
	/** The width of each window control button, in logical pixels. */
	public static inline final CONTROL_WIDTH:Float = 44.0;

	/** The width of the three window controls together. */
	public static inline final CONTROLS_WIDTH:Float = CONTROL_WIDTH * 3;
	final key:String;
	final content:View;
	final controls:WindowControls;
	final height:Float;

	/** A title bar `height` pixels tall that drags the window, showing `content` beside the window `controls`. */
	public function new(key:String, content:View, controls:WindowControls, height:Float = 38) {
		this.key = key;
		this.content = content;
		this.controls = controls;
		this.height = height;
	}
	public function build(context:BuildContext):ViewRoot {
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.fixed(height);
		style.childAlignY = LayoutAlignmentY.Center;
		style.background = context.theme.tokens.surfaceRaised;
		// The toolbar is the shrinkable viewport; fixed window controls never
		// compete with the toolbar's intrinsic content width.
		var viewport = new SizedBox("titlebar-content", content, LayoutAxis.grow(), LayoutAxis.fixed(height));
		viewport.style.clipHorizontal = true;
		var bar = new Row(key,
			[
				new KeyedView("content", viewport),
				new KeyedView("minimize",
					client("minimize", control("Minimize", IconName.WindowMinimize, controls.minimize))),
				new KeyedView("maximize",
					client("maximize",
					control(controls.maximized ? "Restore" : "Maximize",
					controls.maximized ? IconName.WindowRestore : IconName.WindowMaximize,
					controls.toggleMaximize))),
				new KeyedView("close", client("close", control("Close", IconName.Close, controls.close)))
			],
			style);
		var modifier = new RootModifier();
		modifier.windowDecoration = WindowDecorationRegionKind.Drag;
		return context.build(bar, modifier);
	}

	/** `view` as a client region, which takes the pointer instead of dragging the window. */
	static function client(key:String, view:View):View
		return new WindowChrome(key, WindowDecorationRegionKind.Client, view);
	function control(label:String, icon:IconName, action:Void->Void):Button {
		var style = new LayoutStyle();
		style.width = LayoutAxis.fixed(CONTROL_WIDTH);
		style.height = LayoutAxis.fixed(height);
		style.padding = new Insets(14, 0, 14, 0);
		style.radiusTopLeft = style.radiusTopRight = style.radiusBottomLeft = style.radiusBottomRight = 0;
		var button = new Button("",
			style,
			action,
			"window-" + label.toLowerCase(),
			null,
			ButtonVariant.Navigation,
			null,
			null,
			icon,
			null,
			null,
			null,
			null,
			null,
			16,
			label + " window");


		return button;
	}
}
