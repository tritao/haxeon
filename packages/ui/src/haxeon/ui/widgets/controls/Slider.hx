package haxeon.ui.widgets.controls;

import Observable;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Rect;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RenderScope;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiKey;
import haxeon.ui.semantics.AccessibilityRequest;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.style.StyleProperty;
import haxeon.ui.style.StyleState;
import haxeon.ui.style.StyleTarget;

/**
 * Horizontal value slider with Haxe-owned pointer, keyboard, and semantic behavior. It draws only its track and thumb:
 * show a visible label, usually with the value, beside it.
 *
 * The caller owns the value: an edit sets this instance's observable `value`, which reruns the slider's scope at once,
 * and reports it through `onChange`; a parent that builds again with another value replaces it.
 */
class Slider implements ScopeView implements Observable {
	/** Identifies the slider among its siblings, so its state survives rebuilds: required, and never empty. */
	public final key:String;

	/** The name assistive technology announces; not drawn. */
	public final accessibleName:String;
	/** The current value, between `minimum` and `maximum`. */
	public var value:Float;

	/** The value at the start of the track. */
	public final minimum:Float;

	/** The value at the end of the track: greater than `minimum`. */
	public final maximum:Float;

	/** The increment the arrow keys move by and a drag snaps to. */
	public final step:Float;

	/** Whether the slider reacts to input. */
	public var enabled:Bool;

	/** Called with each new value as the user moves the thumb. */
	public var onChange:Null<Float->Void>;

	/** The slider's box. */
	public final style:LayoutStyle;

	/**
	 * A slider from `minimum` to `maximum` showing `value`, clamped into that range. Throws when a number is not finite,
	 * the range is empty, or `step` is not positive.
	 */
	public function new(key:String,
			accessibleName:String,
			value:Float,
			minimum:Float = 0.0,
			maximum:Float = 1.0,
			step:Float = 0.01,
			?onChange:Float->Void,
			?style:LayoutStyle) {
		if (key == null || key.length == 0
			|| !finite(minimum) || !finite(maximum) || !finite(value) || !finite(step) || maximum <= minimum || step
			<= 0.0)
			throw 'Slider "$key" values and range are invalid: value $value, range $minimum to $maximum, step $step';
		this.key = key;
		this.accessibleName = accessibleName == null ? "" : accessibleName;
		this.minimum = minimum;
		this.maximum = maximum;
		this.step = step;
		this.value = clamp(value, minimum, maximum);
		this.onChange = onChange;
		this.style = style == null ? defaultStyle() : style.copy();
		enabled = true;
	}

	public function scopeKey():String return key;

	public function inputsEqual(previous:ScopeView):Bool {
		if (!Std.isOfType(previous, Slider)) return false;
		var other:Slider = cast previous;
		return key == other.key && accessibleName == other.accessibleName && value == other.value
			&& minimum == other.minimum && maximum == other.maximum && step == other.step && enabled == other.enabled
			&& (onChange == null) == (other.onChange == null) && haxeon.Diff.mask(style, other.style) == 0;
	}

	public function build(context:BuildContext):RenderNode return context.mountComponent(this);

	public function buildBody(context:BuildContext):RenderNode return buildControl(context, context.rootId("slider"));

	function buildControl(context:BuildContext, nodeId:haxeon.ui.core.WidgetId):RenderNode {
		var flags = context.styleStates(nodeId, "slider", key, key, null, ["slider"]);
		flags = (!enabled ? flags.insert(StyleState.Disabled) : flags.remove(StyleState.Disabled));
		var computed = context.styleResolver.resolve(new StyleTarget("slider", key, key, null, ["slider"], flags),
			context.inheritedStyle,
			context.theme.styles,
			context.styleSheet,
			style,
			context.environment);
		var node = context.createNode(nodeId, LayoutVisualKind.Custom, computed.toLayoutStyle());
		node.setStyleIdentity("slider", key, key, null, ["slider"]);
		node.states = flags;
		node.computedStyle = computed;
		node.focusable = enabled;
		node.enabled = enabled;
		var semantics = new Semantics(AccessibilityRole.Slider, accessibleName, Std.string(value));
		semantics.actions = AccessibilityAction.SetValue | AccessibilityAction.Increment
			| AccessibilityAction.Decrement;
		semantics.numericValue = value;
		semantics.numericMinimum = minimum;
		semantics.numericMaximum = maximum;
		if (!enabled) semantics.states |= haxeon.ui.semantics.Semantics.AccessibilityState.Disabled;
		node.semantics = semantics;

		var drag = context.lazyState(context.id("drag"), function() return new SliderDrag()).value;
		var latest = context.latestOf(this);
		var setValue = function(next:Float) {
			if (!enabled || !finite(next)) return false;
			var bounded = clamp(next, minimum, maximum);
			var snapped = minimum + Std.int((bounded - minimum) / step + 0.5) * step;
			bounded = clamp(snapped, minimum, maximum);
			if (bounded == value) return false;
			value = bounded;
			var handler = latest().onChange;
			if (handler != null) handler(value);
			return true;
		};
		var valueAtPointer = function(event:UiEvent) {
			if (node.resolved == null) return false;
			var geometry:ResolvedLayoutItem = cast node.resolved;
			var point = geometry.viewportToLayout(event.x, event.y);
			var usableWidth = Math.max(1.0, geometry.width - 20.0);
			var fraction = clamp((point.x - geometry.x - 10.0) / usableWidth, 0.0, 1.0);
			return setValue(minimum + fraction * (maximum - minimum));
		};
		node.onPaint(function(canvas, geometry) {
			var liveStyle:haxeon.ui.style.ComputedStyle = cast node.computedStyle;
			var accent = liveStyle.getColor(StyleProperty.SliderFillColor);
			var muted = liveStyle.getColor(StyleProperty.SliderTrackColor);
			var foreground = liveStyle.getColor(StyleProperty.SliderThumbColor);
			var y = geometry.height * 0.5;
			var start = 10.0;
			var end = Math.max(start + 1.0, geometry.width - 10.0);
			var knob = start + (end - start) * ((value - minimum) / (maximum - minimum));
			canvas.fillRect(new Rect(start, y - 2.0, end - start, 4.0), muted);
			canvas.fillRect(new Rect(start, y - 2.0, Math.max(1.0, knob - start), 4.0), accent);
			canvas.fillRect(new Rect(knob - 6.0, y - 8.0, 12.0, 16.0), foreground);
		}, "value:" + value + ":" + minimum + ":" + maximum);
		node.on(UiEventKind.PointerDown, function(event) {
			if (enabled && event.button == 0) {
				event.capturePointer();
				drag.active = true;
				valueAtPointer(event);
				event.preventDefault();
			}
		});
		node.on(UiEventKind.PointerMove, function(event) {
			if (drag.active) valueAtPointer(event);
		});
		node.on(UiEventKind.PointerUp, function(_) {
			drag.active = false;
		});
		node.on(UiEventKind.PointerCancel, function(_) {
			drag.active = false;
		});

		var handleKey = function(event:UiEvent) {
			if (!enabled) return;
			var handled = true;
			if (event.key == UiKey.Left || event.key == UiKey.Down) setValue(value - step);
			else if (event.key == UiKey.Right || event.key == UiKey.Up) setValue(value + step);
			else if (event.key == UiKey.Home) setValue(minimum);
			else if (event.key == UiKey.End) setValue(maximum);
			else handled = false;
			if (handled) event.preventDefault();
		};
		node.on(UiEventKind.KeyDown, handleKey);
		node.on(UiEventKind.KeyRepeat, handleKey);
		node.on(UiEventKind.AccessibilitySetValue, function(event) {
			if (event.text != null) {
				var parsed = parseNumericValue(event.text);
				if (parsed != null) setValue(parsed);
			}
		});
		node.on(UiEventKind.AccessibilityIncrement, function(event) {
			var action:AccessibilityActionData = cast event.data;
			setValue(value + step * (action != null && action.granularity > 1 ? action.granularity : 1));
		});
		node.on(UiEventKind.AccessibilityDecrement, function(event) {
			var action:AccessibilityActionData = cast event.data;
			setValue(value - step * (action != null && action.granularity > 1 ? action.granularity : 1));
		});
		return node;
	}

	static function defaultStyle():LayoutStyle {
		var result = new LayoutStyle();
		result.width = LayoutAxis.fixed(220.0);
		result.height = LayoutAxis.fixed(32.0);
		return result;
	}

	static inline function clamp(value:Float,
			minimum:Float, maximum:Float):Float return value < minimum ? minimum : value > maximum ? maximum : value;

	static inline function finite(value:Float):Bool return value == value && value - value == 0.0;

	static function parseNumericValue(value:String):Null<Float> {
		var text = value;
		var start = 0;
		var end = text.length;
		while (start < end && whitespace(text.charCodeAt(start))) start++;
		while (end > start && whitespace(text.charCodeAt(end - 1))) end--;
		if (start == end) return null;
		var index = start;
		var sign = 1.0;
		var first = text.charCodeAt(index);
		if (first == 45 || first == 43) {
			if (first == 45) sign = -1.0;
			index++;
		}
		var whole = 0.0;
		var digits = 0;
		while (index < end) {
			var code = text.charCodeAt(index);
			if (code < 48 || code > 57) break;
			whole = whole * 10.0 + code - 48;
			digits++;
			index++;
		}
		var fraction = 0.0;
		var fractionScale = 0.1;
		if (index < end && text.charCodeAt(index) == 46) {
			index++;
			while (index < end) {
				var code = text.charCodeAt(index);
				if (code < 48 || code > 57) break;
				fraction += (code - 48) * fractionScale;
				fractionScale *= 0.1;
				digits++;
				index++;
			}
		}
		if (digits == 0) return null;
		var exponentSign = 1;
		var exponent = 0;
		if (index < end && (text.charCodeAt(index) == 101 || text.charCodeAt(index) == 69)) {
			index++;
			if (index < end && (text.charCodeAt(index) == 45 || text.charCodeAt(index) == 43)) {
				if (text.charCodeAt(index) == 45) exponentSign = -1;
				index++;
			}
			var exponentDigits = 0;
			while (index < end) {
				var code = text.charCodeAt(index);
				if (code < 48 || code > 57) break;
				exponent = exponent * 10 + code - 48;
				if (exponent > 308) return null;
				exponentDigits++;
				index++;
			}
			if (exponentDigits == 0) return null;
		}
		if (index != end) return null;
		var result = sign * (whole + fraction);
		var scale = 1.0;
		for (_ in 0...exponent) scale = exponentSign > 0 ? scale * 10.0 : scale / 10.0;
		result *= scale;
		return finite(result) ? result : null;
	}

	static inline function whitespace(code:Int):Bool return code == 9 || code == 10 || code == 13 || code == 32;
}

/** Whether a pointer is dragging the thumb; scope state, so it survives the reruns the drag causes. */
private class SliderDrag {
	public var active = false;

	public function new() {}
}
