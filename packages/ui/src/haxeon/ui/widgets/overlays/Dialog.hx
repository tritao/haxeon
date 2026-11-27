package haxeon.ui.widgets.overlays;
import haxeon.ui.core.ViewRoot;
import haxeon.ui.style.StyleIdentity;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.View;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.theme.TextRole;

/** Centered modal composition with trapped keyboard focus and dismissal hooks. */
class Dialog implements View {
	final key:Key;
	final content:View;

	/** The dialog's title, which also names it to assistive technology. */
	public final title:String;

	/** Its width, in logical pixels. */
	public final width:Float;

	/** Whether a click outside it dismisses it. */
	public final dismissOnOutside:Bool;

	/** Whether Escape dismisses it. */
	public final dismissOnEscape:Bool;

	/** Called when the user dismisses it; the caller removes it. */
	public final onDismiss:Void->Void;
	internal var hasDismissHandler(default, null):Bool;

	/** A modal dialog titled `title` showing `content`, `width` pixels wide. */
	public function new(key:String, title:String, content:View, ?onDismiss:Void->Void, width:Float = 440.0,
			dismissOnOutside:Bool = true, dismissOnEscape:Bool = true) {
		if (content == null || !finite(width)
			|| width <= 0.0) throw "Dialog requires content and a positive finite width";
		this.key = new Key(key);
		this.title = title == null ? "" : title;
		this.content = content;
		this.width = width;
		hasDismissHandler = onDismiss != null;
		this.onDismiss = onDismiss == null ? function() {}
			: onDismiss;
		this.dismissOnOutside = dismissOnOutside;
		this.dismissOnEscape = dismissOnEscape;
	}

	public function build(context:BuildContext):ViewRoot {
		return context.withScope(key, function() {
			var rootStyle = new LayoutStyle();
			rootStyle.width = LayoutAxis.grow();
			rootStyle.height = LayoutAxis.grow();
			rootStyle.positioning = LayoutPositioning.Absolute;
			rootStyle.overlay = true;
			var rootId = context.rootId("dialog");
			var root = context.styled(rootId, LayoutVisualKind.Box,
				new StyleIdentity("dialog", key.rawValue, key.rawValue, null, ["dialog"]), rootStyle);
			root.focusTrap = true;
			root.hitTestSelf = false;
			var semantics = new Semantics(AccessibilityRole.Dialog, title);
			semantics.states |= AccessibilityState.Modal;
			if (hasDismissHandler) semantics.actions |= AccessibilityAction.Dismiss;
			root.semantics = semantics;

			var backdropStyle = new LayoutStyle();
			backdropStyle.width = LayoutAxis.grow();
			backdropStyle.height = LayoutAxis.grow();
			backdropStyle.positioning = LayoutPositioning.Absolute;
			var backdropId = context.id("backdrop");
			var backdrop = context.styled(backdropId, LayoutVisualKind.Box,
				new StyleIdentity("dialog-backdrop", "backdrop", "backdrop", null, ["dialog"]), backdropStyle);
			if (dismissOnOutside && hasDismissHandler) backdrop.on(UiEventKind.Click, function(event) {
				onDismiss();
				event.stopPropagation();
			});
			root.add(backdrop);

			var centerStyle = new LayoutStyle();
			centerStyle.width = LayoutAxis.grow();
			centerStyle.height = LayoutAxis.grow();
			centerStyle.positioning = LayoutPositioning.Absolute;
			centerStyle.zIndex = 1;
			centerStyle.childAlignX = LayoutAlignmentX.Center;
			centerStyle.childAlignY = LayoutAlignmentY.Center;
			centerStyle.childDistribution = LayoutDistribution.Center;
			var centerId = context.id("dialog-center");
			var center = context.styled(centerId, LayoutVisualKind.Box,
				new StyleIdentity("dialog-center", "center", "center", null, ["dialog"]), centerStyle);
			var panelStyle = new LayoutStyle();
			panelStyle.width = LayoutAxis.fixed(width);
			var panelId = context.id("dialog-panel");
			var panel = context.styled(panelId, LayoutVisualKind.Box,
				new StyleIdentity("dialog-panel", "panel", "panel", null, ["dialog"]), panelStyle);
			var panelComputed = panel.computedStyle;
			if (title.length > 0) {
				var heading = context.withStyleParent(panelComputed,
					function() return context.withScope(new Key("title"), function() {
						var headingId = context.id("heading");
						var headingIdentity = new StyleIdentity("dialog-heading", "title", "title", null,
							["dialog-heading"]);
						var headingComputed = context.resolveStyled(headingId, headingIdentity, new LayoutStyle());
						var node = context.createNode(headingId, LayoutVisualKind.Text,
							headingComputed.toLayoutStyle());
						context.applyStyled(node, headingIdentity, headingComputed);
						node.layout.text = title;
						node.layout.textColor = headingComputed.getColor(haxeon.ui.style.StyleProperty.TextColor);
						node.layout.textStyle =
							node.layout.textStyle.withFontSize(headingComputed.getNumber(haxeon.ui.style.StyleProperty
							.FontSize))
							.withLetterSpacing(headingComputed.getNumber(haxeon.ui.style.StyleProperty.LetterSpacing));
						node.semantics = new Semantics(AccessibilityRole.Heading, title);
						return node;
					}));
				panel.add(heading);
			}
			var child = context.withStyleParent(panelComputed,
				function() return context.withScope(new Key("content"), function() return content.build(context)));
			panel.add(child);
			center.add(panel);
			root.add(center);
			root.on(UiEventKind.KeyDown, function(event) {
				if (event.key == UiKey.Escape && dismissOnEscape && hasDismissHandler) {
					event.preventDefault();
					onDismiss();
				}
			});
			if (hasDismissHandler) root.on(UiEventKind.Activate, function(event) {
				if (event.target.equals(root.id)) onDismiss();
			});
			return root;
		});
	}

	static inline function finite(value:Float):Bool return value == value && value - value == 0.0;
}
