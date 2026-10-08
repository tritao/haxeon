package haxeon.ui.widgets;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.Insets;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.host.WindowControls;
import haxeon.ui.icons.IconName;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ButtonVariant;
import haxeon.ui.widgets.layout.Row;
import nativekit.ffi.NativeKitTypes.WindowDecorationRegionKind;

/** Native drag surface with interactive child exclusions and accessible window controls. */
class WindowTitleBar implements View {
	final key:String;
	final content:View;
	final controls:WindowControls;
	final height:Float;
	public function new(key:String, content:View, controls:WindowControls, height:Float = 38) {
		this.key = key; this.content = content; this.controls = controls; this.height = height;
	}
	public function build(context:BuildContext):RenderNode {
		var style = new LayoutStyle(); style.width = LayoutAxis.grow(); style.height = LayoutAxis.fixed(height);
		style.childAlignY = LayoutAlignmentY.Center; style.background = context.theme.tokens.surfaceRaised;
		var node = new Row(key, [new KeyedView("content", content),
			new KeyedView("minimize", control("Minimize", IconName.WindowMinimize, controls.minimize)),
			new KeyedView("maximize", control(controls.maximized ? "Restore" : "Maximize",
				controls.maximized ? IconName.WindowRestore : IconName.WindowMaximize, controls.toggleMaximize)),
			new KeyedView("close", control("Close", IconName.Close, controls.close))
		], style).build(context);
		node.setWindowDecoration(WindowDecorationRegionKind.Drag);
		node.walk(function(child) {
			if (child.focusable || child.styleType == "button") child.setWindowDecoration(WindowDecorationRegionKind.Client);
		});
		return node;
	}
	function control(label:String, icon:IconName, action:Void->Void):Button {
		var style = new LayoutStyle(); style.width = LayoutAxis.fixed(44); style.height = LayoutAxis.fixed(height);
		style.padding = new Insets(14, 0, 14, 0);
		style.radiusTopLeft = style.radiusTopRight = style.radiusBottomLeft = style.radiusBottomRight = 0;
		var button = new Button("", style, action, "window-" + label.toLowerCase());
		button.accessibilityLabel = label + " window"; button.variant = ButtonVariant.Navigation;
		button.leadingIcon = icon; button.iconSize = 16;
		return button;
	}
}
