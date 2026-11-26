package haxeon.ui.core;

import haxeon.ui.LayoutNode;
import haxeon.ui.Rect;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.WidgetId;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.style.EffectChain;
import haxeon.ui.style.VisualEffect;
import haxeon.ui.style.InkOverflow;
import haxeon.ui.style.Mask;
import haxeon.ui.style.ComputedStyle;
import haxeon.ui.style.StyleProperty;
import haxeon.ui.style.StyleState;

/** Produces deterministic, headless snapshots and readable render-tree dumps. */
class UiInspector {
	// Dump-only records never expose or mutate these arrays. Public snapshots retain independent arrays.
	static final NoEntries:Array<StyleInspectionEntry> = [];
	static final NoRules:Array<StyleSource> = [];
	/** Inspect one node without traversing its descendants. */
	public static function nodeSnapshot(node:RenderNode, focused:Null<WidgetId>):UiNodeSnapshot {
		var result:Array<UiNodeSnapshot> = [];
		append(node, node.parent == null ? 0 : node.parent.id.value, 0, focused, null, null, result, false);
		return result[0];
	}

	/**
	 * Records every node under `root`, in tree order, with style details; `focused`, `hovered` and `pressed` mark
	 * interaction state.
	 */
	public static function snapshot(root:Null<RenderNode>, focused:Null<WidgetId>,
			hovered:Null<WidgetId> = null, pressed:Null<WidgetId> = null):Array<UiNodeSnapshot> {
		return collect(root, focused, hovered, pressed, true);
	}

	static function collect(root:Null<RenderNode>, focused:Null<WidgetId>, hovered:Null<WidgetId>,
			pressed:Null<WidgetId>, includeStyleDetails:Bool):Array<UiNodeSnapshot> {
		var result:Array<UiNodeSnapshot> = [];
		if (root != null) {
			var hoveredOwner = interactionOwner(root, hovered);
			var pressedOwner = interactionOwner(root, pressed);
			append(root, 0, 0, focused, hoveredOwner, pressedOwner, result, true, includeStyleDetails);
		}
		return result;
	}

	/** The tree under `root` as indented text, one line per node, leaving out `ignoredInteractionStates`. */
	public static function dump(root:Null<RenderNode>, focused:Null<WidgetId>,
			ignoredInteractionStates:StyleState = StyleState.empty()):String {
		// Dumps do not use inspection entries or rule provenance. Keep the full public snapshot unchanged.
		return formatDump(collect(root, focused, null, null, false), ignoredInteractionStates);
	}

	static function formatDump(records:Array<UiNodeSnapshot>, ignoredInteractionStates:StyleState):String {
		var lines:Array<String> = [];
		for (record in records) {
			var prefix = "";
			for (_ in 0...record.depth)
				prefix += "  ";
			var line = prefix + "#" + Std.string(record.id) + " " + visualName(record.visualKind) + " ["
				+ number(record.bounds.x) + "," + number(record.bounds.y) + " " + number(record.bounds.width) + "x"
				+ number(record.bounds.height) + "]";
			if (!record.visible)
				line += " hidden";
			if (record.focused)
				line += " focused";
			if (record.hovered && !ignoredInteractionStates.contains(StyleState.Hovered))
				line += " hovered";
			if (record.pressed && !ignoredInteractionStates.contains(StyleState.Pressed))
				line += " pressed";
			if (record.styleType != null)
				line += " type=" + record.styleType;
			if (record.causesIsolation)
				line += " isolation";
			if (record.isolationReasons.length > 0)
				line += " isolation=" + record.isolationReasons.join(",");
			if (record.effectPasses > 0)
				line += " effectPasses=" + Std.string(record.effectPasses);
			if (record.effectDescriptions.length > 0)
				line += " effects=" + record.effectDescriptions.join(",");
			if (record.backdropEffectDescriptions.length > 0)
				line += " backdropEffects=" + record.backdropEffectDescriptions.join(",");
			if (record.maskPasses > 0)
				line += " maskPasses=" + Std.string(record.maskPasses);
			if (record.estimatedIntermediateTargets > 0)
				line += " rtTargets=" + Std.string(record.estimatedIntermediateTargets) + " rtBytes="
					+ number(record.estimatedRenderTargetBytes);
			var states = record.interactionStates.remove(ignoredInteractionStates);
			if (!states.isEmpty())
				line += " states=" + interactionStateNames(states);
			if (record.focusable)
				line += " focusable";
			if (record.zIndex != 0)
				line += " z=" + Std.string(record.zIndex);
			var role = record.role;
			if (role != null)
				line += " role=" + Std.string(role.rawValue) + " states="
					+ Std.string(record.semanticStates.rawValue);
			if (record.label != null && record.label.length > 0)
				line += ' label="' + escape(record.label) + '"';
			if (record.value != null)
				line += ' value="' + escape(record.value) + '"';
			lines.push(line);
		}
		return lines.join("\n");
	}

	static function append(node:RenderNode, parentId:Int, depth:Int,
			focused:Null<WidgetId>, hovered:Null<WidgetId>, pressed:Null<WidgetId>,
			output:Array<UiNodeSnapshot>, recursive:Bool = true, includeStyleDetails:Bool = true):Void {
		var semantics:Null<Semantics> = cast node.semantics;
		var geometry = node.resolved;
		var bounds = geometry == null ? new Rect(0.0, 0.0, 0.0, 0.0) : geometry.bounds();
		var clip = geometry == null ? new Rect(0.0, 0.0, 0.0, 0.0) : geometry.clipBounds;
		var content = geometry == null ? new Rect(0.0, 0.0, 0.0, 0.0) : geometry.contentBounds;
		var role:Null<AccessibilityRole> = semantics == null ? null : semantics.role;
		var styleEntries:Array<StyleInspectionEntry> = includeStyleDetails ? [] : NoEntries;
		var matchingStyleRules:Array<StyleSource> = includeStyleDetails ? [] : NoRules;
		if (node.computedStyle != null) {
			if (includeStyleDetails) {
				styleEntries = node.computedStyle.entries();
				matchingStyleRules = node.computedStyle.matchingStyleRules();
			} else node.computedStyle.copyInspectionValues();
		}
		var style = node.computedStyle;
		var effects:Null<EffectChain> = style == null ? null : style.getEffects(StyleProperty.Effects);
		var backdropEffects:Null<EffectChain> =
			style == null ? null : style.getEffects(StyleProperty.BackdropEffects);
		var mask:Null<Mask> = style == null ? null : style.getMask();
		var opacity:Float = style == null ? 1.0 : style.getNumber(StyleProperty.Opacity);
		var overflow:InkOverflow = effects == null ? InkOverflow.zero() : effects.inkOverflow();
		var paintBounds = new Rect(bounds.x - overflow.left, bounds.y - overflow.top,
			bounds.width + overflow.left + overflow.right,
			bounds.height + overflow.top + overflow.bottom);
		var foregroundEffectPasses = effectPassCount(effects);
		var backdropEffectPasses = effectPassCount(backdropEffects);
		var effectPasses = foregroundEffectPasses + backdropEffectPasses;
		var maskPasses = mask == null ? 0 : 1;
		var isolationReasons:Array<String> = [];
		if (opacity < 1.0)
			isolationReasons.push("opacity");
		if (foregroundEffectPasses > 0)
			isolationReasons.push("effects");
		if (backdropEffectPasses > 0)
			isolationReasons.push("backdrop-effects");
		if (maskPasses > 0)
			isolationReasons.push("mask");
		var isolated = isolationReasons.length > 0;
		var ownArea = paintBounds.width * paintBounds.height;
		var backdropArea = bounds.width * bounds.height;
		var estimatedBytes = (isolated ? ownArea : 0.0) * 4.0 + ownArea * foregroundEffectPasses * 4.0 + maskPasses
			* ownArea * 4.0 + backdropArea * backdropEffectPasses * 4.0;
		var estimatedIntermediateTargets = (isolated ? 1 : 0) + foregroundEffectPasses + maskPasses
			+ backdropEffectPasses;
		var effectDescriptions = describeEffects(effects);
		var backdropEffectDescriptions = describeEffects(backdropEffects);
		output.push(new UiNodeSnapshot(node.id.value, parentId, depth,
			node.layout.visualKind, bounds, clip, content,
			geometry != null && geometry.visible, node.enabled, node.focusable,
			focused != null && focused.equals(node.id),
			(node.states).contains(StyleState.Hovered) || hovered != null && hovered.equals(node.id),
			(node.states).contains(StyleState.Pressed) || pressed != null && pressed.equals(node.id),
			node.layout.style.zIndex,
			role, semantics == null ? haxeon.ui.semantics.Semantics.AccessibilityState.empty() : semantics.states,
			semantics == null ? null : semantics.label,
			semantics == null ? null : semantics.value,
			semantics == null ? haxeon.ui.semantics.Semantics.AccessibilityAction.empty() : semantics.actions,
			node.states, node.styleType, node.computedStyle,
			styleEntries, matchingStyleRules, isolated, overflow, paintBounds,
			effectPasses, estimatedBytes,
			new UiNodeEffectInfo(effectDescriptions, backdropEffectDescriptions,
			backdropEffectPasses, maskPasses, isolationReasons, estimatedIntermediateTargets)));
		if (recursive) for (child in node.children)
			append(child, node.id.value, depth + 1, focused, hovered, pressed, output, true, includeStyleDetails);
	}

	static function effectPassCount(chain:Null<EffectChain>):Int {
		if (chain == null || chain.effects.length == 0)
			return 0;
		var result = 0;
		var colorPending = false;
		for (effect in chain.effects) {
			switch effect.kind {
				case EffectKind.Brightness | EffectKind.Contrast | EffectKind.Saturate | EffectKind.HueRotate
					| EffectKind.ColorMatrix:
					colorPending = true;
				case EffectKind.Blur | EffectKind.DropShadow:
					if (colorPending) {
						result++;
						colorPending = false;
					}
					result += 2;
				case EffectKind.Custom:
					if (colorPending) {
						result++;
						colorPending = false;
					}
					result++;
				default:
			}
		}
		return result + (colorPending ? 1 : 0);
	}

	static function describeEffects(chain:Null<EffectChain>):Array<String> {
		var result:Array<String> = [];
		if (chain != null)
			for (effect in chain.effects)
				result.push(effect.describe());
		return result;
	}

	static function interactionOwner(root:RenderNode, id:Null<WidgetId>):Null<WidgetId> {
		if (id == null)
			return null;
		var node = root.find(id);
		if (node == null)
			return id;
		var semantic:Null<WidgetId> = null;
		var current:Null<RenderNode> = node;
		while (current != null) {
			var present:RenderNode = cast current;
			if (present.semantics != null && semantic == null)
				semantic = present.id;
			if (present.focusable)
				return present.id;
			current = present.parent;
		}
		return semantic == null ? id : semantic;
	}

	static function visualName(kind:LayoutVisualKind):String {
		return switch kind {
			case LayoutVisualKind.Box: "Box";
			case LayoutVisualKind.Text: "Text";
			case LayoutVisualKind.Image: "Image";
			case LayoutVisualKind.Custom: "Custom";
		};
	}

	static function number(value:Float):String
		return Std.string(Std.int(value * 100.0) / 100.0);

	static function interactionStateNames(flags:StyleState):String {
		var names:Array<String> = [];
		if (flags.contains(StyleState.Hovered)) names.push("hovered");
		if (flags.contains(StyleState.Pressed)) names.push("pressed");
		if (flags.contains(StyleState.Focused)) names.push("focused");
		if (flags.contains(StyleState.Disabled)) names.push("disabled");
		if (flags.contains(StyleState.Selected)) names.push("selected");
		if (flags.contains(StyleState.Checked)) names.push("checked");
		return names.join(",");
	}

	static function escape(value:String):String {
		var result = new StringBuf();
		for (index in 0...value.length) {
			switch value.charCodeAt(index) {
				case 92: result.add("\\\\");
				case 34: result.add("\\\"");
				case 10: result.add("\\n");
				case 13: result.add("\\r");
				case code: result.addChar(code);
			}
		}
		return result.toString();
	}
}

/** Grouped effect diagnostics carried by a node inspection snapshot. */
internal class UiNodeEffectInfo {
	public final effectDescriptions:Array<String>;
	public final backdropEffectDescriptions:Array<String>;
	public final backdropEffectPasses:Int;
	public final maskPasses:Int;
	public final isolationReasons:Array<String>;
	public final estimatedIntermediateTargets:Int;

	public function new(effectDescriptions:Array<String> = null,
			backdropEffectDescriptions:Array<String> = null, backdropEffectPasses:Int = 0,
			maskPasses:Int = 0, isolationReasons:Array<String> = null,
			estimatedIntermediateTargets:Int = 0) {
		this.effectDescriptions = effectDescriptions == null ? [] : effectDescriptions.copy();
		this.backdropEffectDescriptions = backdropEffectDescriptions == null
			? [] : backdropEffectDescriptions.copy();
		this.backdropEffectPasses = backdropEffectPasses;
		this.maskPasses = maskPasses;
		this.isolationReasons = isolationReasons == null ? [] : isolationReasons.copy();
		this.estimatedIntermediateTargets = estimatedIntermediateTargets;
	}
}

/** Stable headless inspection record for one resolved Haxe render node. */
class UiNodeSnapshot {
	/** The node's id. */
	public final id:Int;

	/** Its parent's id, or zero for the root. */
	public final parentId:Int;

	/** How deep it is; the root is zero. */
	public final depth:Int;

	/** What it draws: a box, text, an image and so on. */
	public final visualKind:LayoutVisualKind;

	/** Its laid-out bounds. */
	public final bounds:Rect;

	/** The area it is clipped to. */
	public final clipBounds:Rect;

	/** Its content area, inside padding. */
	public final contentBounds:Rect;

	/** Whether it is shown. */
	public final visible:Bool;

	/** Whether it reacts to input. */
	public final enabled:Bool;

	/** Whether it can take focus. */
	public final focusable:Bool;

	/** Whether it has focus. */
	public final focused:Bool;

	/** Whether the pointer is over it. */
	public final hovered:Bool;

	/** Whether it is being pressed. */
	public final pressed:Bool;

	/** Its interaction states, as style rules see them. */
	public final interactionStates:StyleState;

	/** The style type it matches rules by, or null. */
	public final styleType:Null<String>;

	/** Its resolved style, or null. */
	public final computedStyle:Null<ComputedStyle>;

	/** Each resolved property with the rule it came from. */
	public final styleEntries:Array<StyleInspectionEntry>;

	/** The style rules that matched it. */
	public final matchingStyleRules:Array<StyleSource>;
	/** True when opacity, effects, backdrop effects, or a mask require isolation. */
	public final causesIsolation:Bool;
	/** Logical ink expansion requested by subtree effects. */
	public final inkOverflow:InkOverflow;
	/** Logical paint bounds after applying ink overflow. */
	public final paintBounds:Rect;
	/** Estimated sampled effect passes for this node and its backdrop. */
	public final effectPasses:Int;
	/** Descriptions of foreground effects in application order. */
	public final effectDescriptions:Array<String>;
	/** Descriptions of effects applied to the backdrop input. */
	public final backdropEffectDescriptions:Array<String>;
	/** Estimated effect passes applied to the backdrop input. */
	public final backdropEffectPasses:Int;
	/** Number of mask composition passes estimated for this node. */
	public final maskPasses:Int;
	/** Reasons this node requires an isolated layer. */
	public final isolationReasons:Array<String>;
	/** Estimated number of intermediate RGBA targets used by this node. */
	public final estimatedIntermediateTargets:Int;
	/** Logical RGBA bytes estimated for the node's intermediate targets. */
	public final estimatedRenderTargetBytes:Float;

	/** Its stacking order among siblings. */
	public final zIndex:Int;
	/** The semantic role, or null for a node without semantics. */
	public final role:Null<AccessibilityRole>;

	/** Its accessibility states. */
	public final semanticStates:AccessibilityState;

	/** Its accessible name, or null. */
	public final label:Null<String>;

	/** Its accessible value, or null. */
	public final value:Null<String>;

	/** The accessibility actions it supports. */
	public final actions:AccessibilityAction;

	internal function new(id:Int, parentId:Int, depth:Int, visualKind:LayoutVisualKind, bounds:Rect,
			clipBounds:Rect, contentBounds:Rect, visible:Bool, enabled:Bool,
			focusable:Bool, focused:Bool, hovered:Bool, pressed:Bool, zIndex:Int, role:Null<AccessibilityRole>,
			semanticStates:AccessibilityState, label:Null<String>, value:Null<String>, actions:AccessibilityAction,
			interactionStates:StyleState = StyleState.empty(), styleType:Null<String> = null,
			computedStyle:Null<ComputedStyle> = null,
			?styleEntries:Array<StyleInspectionEntry>, ?matchingStyleRules:Array<StyleSource>,
			causesIsolation:Bool = false, ?inkOverflow:InkOverflow, ?paintBounds:Rect,
			effectPasses:Int = 0, estimatedRenderTargetBytes:Float = 0.0,
			?effectInfo:UiNodeEffectInfo) {
		this.id = id;
		this.parentId = parentId;
		this.depth = depth;
		this.visualKind = visualKind;
		this.bounds = bounds;
		this.clipBounds = clipBounds;
		this.contentBounds = contentBounds;
		this.visible = visible;
		this.enabled = enabled;
		this.focusable = focusable;
		this.focused = focused;
		this.hovered = hovered;
		this.pressed = pressed;
		this.interactionStates = interactionStates;
		this.styleType = styleType;
		this.computedStyle = computedStyle;
		this.styleEntries = styleEntries == null ? [] : styleEntries;
		this.matchingStyleRules = matchingStyleRules == null ? [] : matchingStyleRules;
		this.causesIsolation = causesIsolation;
		this.inkOverflow = inkOverflow == null ? InkOverflow.zero() : inkOverflow;
		this.paintBounds = paintBounds == null ? bounds : paintBounds;
		this.effectPasses = effectPasses;
		this.effectDescriptions = effectInfo == null ? [] : effectInfo.effectDescriptions;
		this.backdropEffectDescriptions = effectInfo == null ? [] : effectInfo.backdropEffectDescriptions;
		this.backdropEffectPasses = effectInfo == null ? 0 : effectInfo.backdropEffectPasses;
		this.maskPasses = effectInfo == null ? 0 : effectInfo.maskPasses;
		this.isolationReasons = effectInfo == null ? [] : effectInfo.isolationReasons;
		this.estimatedIntermediateTargets = effectInfo == null ? 0 : effectInfo.estimatedIntermediateTargets;
		this.estimatedRenderTargetBytes = estimatedRenderTargetBytes;
		this.zIndex = zIndex;
		this.role = role;
		this.semanticStates = semanticStates;
		this.label = label;
		this.value = value;
		this.actions = actions;
	}
}
