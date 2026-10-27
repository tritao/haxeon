import haxeon.platform.NativeKitRuntime;
import haxeon.ui.FontCollection;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.UiModifier;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconName;
import haxeon.ui.semantics.AccessibilityAction;
import haxeon.ui.style.StyleState;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.Checkbox;
import haxeon.ui.widgets.controls.IconButton;
import haxeon.ui.widgets.controls.Radio;
import haxeon.ui.widgets.collections.VirtualGrid;
import haxeon.ui.widgets.text.Text;

class ActivationTests {
    static function check(value:Bool, message:String):Void if (!value) throw message;
    static function style():LayoutStyle {
        var result = new LayoutStyle();
        result.width = LayoutAxis.fixed(140);
        result.height = LayoutAxis.fixed(40);
        return result;
    }

    static function exercise(fonts:FontCollection, view:View, label:String, calls:Void->Int, disabled:Bool = false):Void {
        var ui = new UiContext(null, fonts);
        var root = ui.submit(view, new LayoutFrame(320, 160));
        var target:Null<RenderNode> = null;
        root.walk(function(node) {
            if (target == null && node.semantics != null &&
                (node.semantics.actions & AccessibilityAction.Activate) != 0 &&
                (label == "" || node.semantics.label == label)) target = node;
        });
        if (target == null) throw "Missing activation target: " + label;
        var node:RenderNode = cast target;
        var bounds = node.globalBounds();
        var x = bounds.x + bounds.width / 2, y = bounds.y + bounds.height / 2;
        var rawClicks = 0;
        node.on(UiEventKind.Click, function(_) rawClicks++);
        for (button in [1, 2, 3, 4]) {
            ui.pointerDown(x, y, button);
            check((ui.interactionStates.get(node.id) & StyleState.Pressed) == 0,
                label + ": auxiliary press showed primary pressed feedback");
            ui.pointerUp(x, y, button);
        }
        check(calls() == 0 && (disabled || rawClicks == 4), label + ": secondary clicks activated or stopped routing");
        for (buttons in [[1, 0], [0, 1]]) {
            ui.pointerDown(x, y, buttons[0]);
            ui.pointerUp(x, y, buttons[1]);
        }
        check(calls() == 0 && (disabled || rawClicks == 4), label + ": mismatched press/release emitted a click");
        ui.pointerDown(x, y, 0);
        ui.pointerCancel(0, x, y);
        ui.pointerUp(x, y, 0);
        ui.pointerDown(x, y, 0);
        ui.pointerUp(500, 500, 0);
        check(calls() == 0, label + ": cancelled or outside release activated");
        ui.pointerDown(x, y, 0, UiModifier.Control);
        check(disabled || (ui.interactionStates.get(node.id) & StyleState.Pressed) != 0,
            label + ": primary press lost pressed feedback");
        ui.pointerUp(x, y, 0, UiModifier.Control);
        if (disabled) {
            check(calls() == 0 && !ui.focusWidget(node.id) &&
                !ui.accessibilityAction(node.id.value, AccessibilityAction.Activate, null, -1, -1, 1),
                label + ": disabled control activated");
        } else {
            check(calls() == 1, label + ": primary click did not activate exactly once");
            check(ui.accessibilityAction(node.id.value, AccessibilityAction.Activate, null, -1, -1, 1),
                label + ": accessibility activation failed");
            check(ui.focusWidget(node.id), label + ": keyboard focus failed");
            ui.key(UiEventKind.KeyDown, UiKey.Enter);
            ui.key(UiEventKind.KeyDown, UiKey.Space);
            check(calls() == 4, label + ": keyboard/accessibility activation changed");
        }
        ui.dispose();
    }

    static function main():Int {
        var runtime = NativeKitRuntime.start();
        var fonts = FontCollection.create();
        fonts.addSystemFallbacks();
        var calls = 0;
        exercise(fonts, new Button("Button", style(), function() calls++), "Button", function() return calls);
        calls = 0;
        var eventButton = new Button("Event button", style());
        eventButton.onClickEvent = function(event) {
            if (event.kind == UiEventKind.Click)
                check(event.button == 0 && (event.modifiers & UiModifier.Control) != 0, "Click event metadata changed");
            calls++;
        };
        exercise(fonts, eventButton, "Event button", function() return calls);
        calls = 0;
        exercise(fonts, new IconButton("icon", IconName.Settings, "Icon", function() calls++, style()), "Icon", function() return calls);
        calls = 0;
        exercise(fonts, new Checkbox("check", "Checkbox", false, function(_) calls++, style()), "Checkbox", function() return calls);
        calls = 0;
        exercise(fonts, new Radio("radio", "Radio", "value", false, function(_) calls++, style()), "Radio", function() return calls);
        calls = 0;
        exercise(fonts, new VirtualGrid("grid", 1, 1, 40, 140, function(_, _) return new Text("Cell"),
            style(), null, null, 140, 40, function(_, _) calls++), "", function() return calls);
        calls = 0;
        var disabled = new Button("Disabled", style(), function() calls++);
        disabled.enabled = false;
        exercise(fonts, disabled, "Disabled", function() return calls, true);
        fonts.dispose();
        runtime.dispose();
        Sys.println("PASS: primary-only controls, raw auxiliary clicks, matching releases, cancellation, keyboard and accessibility");
        return 0;
    }
}
