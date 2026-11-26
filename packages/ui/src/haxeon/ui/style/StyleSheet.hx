package haxeon.ui.style;

import haxeon.ui.animation.AnimationController;
import haxeon.ui.style.StyleEnvironment;
import haxeon.ui.style.StyleProperty.StylePropertyBase;

import haxeon.ui.style.StyleResolver;
/** Ordered collection of typed style rules. */
class StyleSheet {
	static var nextIdentity:Int = 0;

	/** Stable resolver-local identity, distinct from the human-readable name. */
	public final identity:Int;

	/** The sheet's name, for inspection. */
	public final name:String;

	/** The rules, in order. */
	public final rules(default, null):Array<StyleRule>;

	/** The transitions, one per property at most. */
	public final transitions(default, null):Array<StyleTransition>;

	/** Counts the changes, so styles are resolved again. */
	public var revision(default, null):Int;

	/** An empty sheet named `name`. */
	public function new(?name:String) {
		identity = nextIdentity++;
		this.name = name == null || name.length == 0 ? "StyleSheet" : name;
		rules = [];
		transitions = [];
		revision = 0;
	}

	/** Adds a rule setting `declarations` on boxes `selector` matches, and returns it. */
	public function rule(selector:StyleSelector, declarations:Array<StyleValue>):StyleRule {
		var result = new StyleRule(name, selector, declarations, rules.length);
		rules.push(result);
		revision++;
		return result;
	}

	/** Adds a rule that applies only while the environment meets `condition`. Throws without a condition. */
	public function when(condition:EnvironmentCondition, selector:StyleSelector,
			declarations:Array<StyleValue>):StyleRule {
		if (condition == null)
			throw "Conditional style rules require an environment condition";
		var result = new StyleRule(name, selector, declarations, rules.length, condition);
		rules.push(result);
		revision++;
		return result;
	}

	/** Removes every rule and transition. */
	public function clear():Void {
		rules.resize(0);
		transitions.resize(0);
		revision++;
	}

	/** Whether it has no rules and no transitions. */
	public function isEmpty():Bool
		return rules.length == 0;

	/** Animates changes of `property` over `duration` seconds with `easing`, replacing any earlier transition of it. */
	public function transition(property:StylePropertyBase, duration:Float,
			easing:Easing = Easing.EaseOut):StyleTransition {
		var result = new StyleTransition(property, duration, easing);
		transitions.push(result);
		revision++;
		return result;
	}

	/** The transition of `property`, or null. */
	public function transitionFor(property:StylePropertyBase):Null<StyleTransition> {
		for (transition in transitions)
			if (transition.property.name == property.name)
				return transition;
		return null;
	}
}

/** One ordered typed selector/declaration rule. */
class StyleRule {
	/** Which boxes the rule applies to. */
	public final selector:StyleSelector;
	/** The values it sets. */
	public final declarations:Array<StyleValue>;
	/** Its place in its sheet: later rules win over earlier ones. */
	public final order:Int;
	/** The name of its sheet. */
	public final stylesheet:String;
	/** The environment it applies in; always when null. */
	public final condition:Null<EnvironmentCondition>;

	/** A rule; sheets make them with `StyleSheet.rule` and `when`. Throws without a selector or declarations. */
	public function new(stylesheet:String, selector:StyleSelector,
			declarations:Array<StyleValue>, order:Int, ?condition:EnvironmentCondition) {
		if (selector == null || declarations == null || declarations.length == 0)
			throw "Style rules require a selector and declarations";
		this.stylesheet = stylesheet == null ? "" : stylesheet;
		this.selector = selector;
		this.declarations = declarations.copy();
		this.order = order;
		this.condition = condition;
	}

	/** Whether the rule applies to `target` in `environment`. */
	public function matches(target:StyleTarget, ?environment:StyleEnvironment):Bool
		return selector.matches(target) && (condition == null || condition.matches(environment));
}

/** Typed selector; deliberately does not parse or emit CSS syntax. */
class StyleSelector {
	/** The widget type it requires, or null for any. */
	public final widgetType:Null<String>;
	/** The key it requires, or null for any. */
	public final keyValue:Null<String>;
	/** The ID it requires, or null for any. */
	public final idValue:Null<String>;
	/** The classes it requires, all of them. */
	public final classNames:Array<String>;
	/** The tags it requires, all of them. */
	public final tagNames:Array<String>;
	/** The states it requires, all of them. */
	public final stateMask:StyleState;

	function new(?widgetType:String,
			?keyValue:String,
			?idValue:String,
			?classNames:Array<String>,
			?tagNames:Array<String>,
			stateMask:StyleState = StyleState.empty()) {
		this.widgetType = widgetType;
		this.keyValue = keyValue;
		this.idValue = idValue;
		this.classNames = classNames == null ? [] : classNames;
		this.tagNames = tagNames == null ? [] : tagNames;
		this.stateMask = stateMask;
	}

	/** Matches every box. */
	public static function any():StyleSelector return new StyleSelector();

	/** Matches widgets of `type`, such as "button". */
	public static function widget(type:String):StyleSelector {
		if (type == null || type.length == 0) throw "Widget selectors require a type";
		return new StyleSelector(type);
	}

	/** Matches the box keyed `value`. */
	public static function key(value:String):StyleSelector {
		if (value == null || value.length == 0) throw "Key selectors require a value";
		return new StyleSelector(null, value);
	}

	/** Matches the box with the ID `value`. */
	public static function id(value:String):StyleSelector {
		if (value == null || value.length == 0) throw "ID selectors require a value";
		return new StyleSelector(null, null, value);
	}

	/** Adds a class constraint and returns this selector for fluent composition. */
	public function className(value:String):StyleSelector {
		if (value == null || value.length == 0) throw "Class selectors require a value";
		classNames.push(value);
		return this;
	}

	/** Adds a semantic/tag constraint and returns this selector for fluent composition. */
	public function tag(value:String):StyleSelector {
		if (value == null || value.length == 0) throw "Tag selectors require a value";
		tagNames.push(value);
		return this;
	}

	/** Adds a pseudo-state constraint and returns this selector for fluent composition. */
	public function state(value:StyleState):StyleSelector {
		stateMask |= value;
		return this;
	}

	/** Whether it requires any state. */
	public function hasState():Bool return !stateMask.isEmpty();

	/** Whether `target` meets every requirement. */
	public inline function matches(target:StyleTarget):Bool return matchesWithoutStates(target)
		&& target.states.contains(stateMask);

	/** Structural matching for queries about rules that may become active. */
	public function matchesWithoutStates(target:StyleTarget):Bool {
		return target != null && matchesIdentity(target.widgetType, target.key, target.id, target.classes, target.tags);
	}

	/** Match an existing node's selector identity without allocating a temporary target. */
	public function matchesIdentity(type:String,
			key:Null<String>,
			id:Null<String>,
			classes:Array<String>,
			tags:Array<String>):Bool {
		if (widgetType != null && widgetType != type) return false;
		if (keyValue != null && keyValue != key) return false;
		if (idValue != null && idValue != id) return false;
		for (name in classNames) if (classes.indexOf(name) < 0) return false;
		for (name in tagNames) if (tags.indexOf(name) < 0) return false;
		return true;
	}

	/** Deterministic cascade specificity, used only between matching rules in one layer. */
	public function specificity():Int return (idValue == null
		? 0 : 100) + (classNames.length + tagNames.length + countStates(stateMask)) * 10 + (widgetType == null ? 0 : 1);

	/** The selector as text, for inspection. */
	public function describe():String {
		var result = widgetType == null ? "*" : widgetType;
		if (idValue != null) result += "#" + idValue;
		if (keyValue != null) result += "@" + keyValue;
		for (name in classNames) result += "." + name;
		for (name in tagNames) result += "[" + name + "]";
		var states:Array<String> = [];
		if (stateMask.contains(StyleState.Hovered)) states.push("hovered");
		if (stateMask.contains(StyleState.Pressed)) states.push("pressed");
		if (stateMask.contains(StyleState.Focused)) states.push("focused");
		if (stateMask.contains(StyleState.Disabled)) states.push("disabled");
		if (stateMask.contains(StyleState.Selected)) states.push("selected");
		if (stateMask.contains(StyleState.Checked)) states.push("checked");
		for (state in states) result += ":" + state;
		return result;
	}
	static function countStates(states:StyleState):Int {
		var remaining = states.rawValue(), result = 0;
		while (remaining != 0) {
			result += remaining & 1;
			remaining = remaining >>> 1;
		}
		return result;
	}
}

/** Which rules of a theme sheet and an application sheet match a widget on hover, indexed by widget type. */
internal class HoverRuleIndex {
	/** The style revision the types were collected at. */
	var revision:Int = -1;

	/** The widget types of the rules that match on hover; any type, when one of them names none. */
	final types:Map<String, Bool> = new Map();

	var anyType:Bool = false;

	public function new() {}

	/** Whether a rule of `theme` or `application` matches this identity on hover; `revision` names the sheets' state. */
	public function matches(theme:StyleSheet, application:StyleSheet, revision:Int, type:String, key:Null<String>,
			id:Null<String>, classes:Array<String>, tags:Array<String>):Bool {
		// Most types no hover rule names: answered from the types the current sheets name, without building a target.
		if (this.revision != revision) {
			this.revision = revision;
			types.clear();
			anyType = false;
			collect(theme);
			collect(application);
		}
		if (!anyType && !types.exists(type)) return false;
		return sheetMatches(theme, type, key, id, classes, tags)
			|| sheetMatches(application, type, key, id, classes, tags);
	}

	function collect(sheet:StyleSheet):Void {
		for (rule in sheet.rules) if (rule.selector.stateMask.contains(StyleState.Hovered)) {
			var type = rule.selector.widgetType;
			if (type == null) anyType = true;
			else types.set(type, true);
		}
	}

	static function sheetMatches(sheet:StyleSheet, type:String, key:Null<String>, id:Null<String>,
			classes:Array<String>,
			tags:Array<String>):Bool {
		for (rule in sheet.rules) if (rule.selector.stateMask.contains(StyleState.Hovered)
			&& rule.selector.matchesIdentity(type, key, id, classes, tags)) return true;
		return false;
	}
}
