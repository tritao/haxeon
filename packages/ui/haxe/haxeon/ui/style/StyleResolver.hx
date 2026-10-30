package haxeon.ui.style;

import haxeon.ui.widgets.layout.Padding;


import haxeon.ui.Color;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Transform2D;
import haxeon.ui.animation.AnimationScheduler;

/** Deterministic framework/inheritance/theme/application/state/local cascade. */
class StyleResolver {
	static inline var MaxCacheEntries:Int = 8192;
	static final LocalTextSource = new StyleSource("local", "text", -1, "local");

	final frameworkSource:StyleSource;
	final scheduler:Null<AnimationScheduler>;
	final animatedValues:Map<String, Dynamic>;
	final targets:Map<String, Dynamic>;
	final activeAnimations:Map<String, StyleTransitionAnimation>;
	final cache:Map<Int, Array<StyleResolverCacheEntry>>;
	final localFingerprints:Map<Int, StyleResolverLocalFingerprint>;
	final stringHashes:Map<String, Int>;
	var cacheEntryCount:Int;
	var cacheHitCount:Int;
	var cacheMissCount:Int;
	var resolutionCount:Int;
	var localFingerprintCount:Int;
	var nextLocalFingerprint:Int;
	var stringHashCount:Int;

	/** Number of cacheable resolutions served from the computed-style cache. */
	public var cacheHits(get, never):Int;
	/** Number of cacheable resolutions that required a fresh cascade. */
	public var cacheMisses(get, never):Int;
	/** Total number of style resolution calls made by this resolver. */
	public var resolutions(get, never):Int;
	/** Number of entries currently held by this resolver's bounded cache. */
	public var cachedStyleCount(get, never):Int;

	public function new(?scheduler:AnimationScheduler) {
		frameworkSource = new StyleSource("framework", "default", -1, "framework");
		this.scheduler = scheduler;
		animatedValues = new Map();
		targets = new Map();
		activeAnimations = new Map();
		cache = new Map();
		localFingerprints = new Map();
		stringHashes = new Map();
		cacheEntryCount = 0;
		cacheHitCount = 0;
		cacheMissCount = 0;
		resolutionCount = 0;
		localFingerprintCount = 0;
		nextLocalFingerprint = 0;
		stringHashCount = 0;
	}

	function get_cacheHits():Int
		return cacheHitCount;

	function get_cacheMisses():Int
		return cacheMissCount;

	function get_resolutions():Int
		return resolutionCount;

	function get_cachedStyleCount():Int
		return cacheEntryCount;

	/** Bounded-run diagnostics for retained styles and transition state. */
	public function diagnosticCounts():{styles:Int, localStyles:Int, targets:Int, animations:Int} {
		var targetCount = 0;
		var animationCount = 0;
		for (_ in targets.keys()) targetCount++;
		for (_ in activeAnimations.keys()) animationCount++;
		return {styles: cacheEntryCount, localStyles: localFingerprintCount,
			targets: targetCount, animations: animationCount};
	}

	/** Drops resolved styles while retaining animation state and counters. */
	public function clearCache():Void {
		cache.clear();
		localFingerprints.clear();
		stringHashes.clear();
		cacheEntryCount = 0;
		localFingerprintCount = 0;
		stringHashCount = 0;
	}

	public function resolve(target:StyleTarget, ?parent:ComputedStyle,
			?theme:StyleSheet, ?application:StyleSheet, ?local:LayoutStyle,
			?environment:StyleEnvironment, ?localTextColor:Color):ComputedStyle {
		if (target == null)
			throw "Style resolution requires a target";
		resolutionCount++;

		// Transition values depend on scheduler time and must be resolved live. A
		// sheet containing transitions conservatively disables caching for the
		// whole target, while ordinary styles remain pure and cacheable.
		var cacheable = !hasTransitions(theme, application);
		var parentInheritedKey:Null<String> = null;
		var localStyleKey:Null<String> = null;
		var themeIdentity = theme == null ? -1 : theme.identity;
		var themeRevision = theme == null ? -1 : theme.revision;
		var applicationIdentity = application == null ? -1 : application.identity;
		var applicationRevision = application == null ? -1 : application.revision;
		var environmentIdentity = environment == null ? -1 : environment.identity;
		var environmentRevision = environment == null ? -1 : environment.revision;
		var cacheFingerprint = 0;
		if (cacheable) {
			parentInheritedKey = parentKey(parent);
			localStyleKey = localKey(local);
			cacheFingerprint = cacheHash(target.selectorHash, target.states,
				parentInheritedKey, themeIdentity, themeRevision, applicationIdentity,
				applicationRevision, localStyleKey, environmentIdentity, environmentRevision);
			cacheFingerprint = colorFingerprint(cacheFingerprint, localTextColor);
		}
		if (cacheable) {
			var bucket = cache.get(cacheFingerprint);
			if (bucket != null)
				for (entry in bucket)
					if (entry.matches(target, target.states, parentInheritedKey,
						themeIdentity, themeRevision, applicationIdentity, applicationRevision,
						localStyleKey, environmentIdentity, environmentRevision, localTextColor)) {
						cacheHitCount++;
						return entry.style.fork();
					}
			cacheMissCount++;
		}
		if (cacheable && cacheEntryCount >= MaxCacheEntries) {
			cache.clear();
			cacheEntryCount = 0;
		}

		var result = new ComputedStyle();
		for (property in StyleProperty.all())
			result.set(property, property.defaultValue, frameworkSource);

		if (parent != null)
			for (property in StyleProperty.all())
				if (property.inherited && parent.has(property))
					result.set(property, parent.get(property), parent.source(property));

		applySheet(result, target, theme, false, "theme", environment);
		applySheet(result, target, application, false, "application", environment);
		applySheet(result, target, theme, true, "theme-state", environment);
		applySheet(result, target, application, true, "application-state", environment);
		applyLocal(result, local);
		applyTransitions(result, target, theme, application);
		if (localTextColor != null) result.set(StyleProperty.TextColor, localTextColor, LocalTextSource);
		if (cacheable) {
			var bucket = cache.get(cacheFingerprint);
			if (bucket == null) {
				bucket = [];
				cache.set(cacheFingerprint, bucket);
			}
			bucket.push(new StyleResolverCacheEntry(target, target.states,
				parentInheritedKey, themeIdentity, themeRevision, applicationIdentity,
				applicationRevision, localStyleKey, environmentIdentity, environmentRevision,
				result.fork(), localTextColor));
			cacheEntryCount++;
		}
		return result;
	}

	function hasTransitions(theme:Null<StyleSheet>, application:Null<StyleSheet>):Bool
		return (theme != null && theme.transitions.length > 0) ||
			(application != null && application.transitions.length > 0);

	function cacheHash(targetHash:Int, states:Int, parentKey:String,
			themeIdentity:Int, themeRevision:Int, applicationIdentity:Int,
			applicationRevision:Int, localKey:String, environmentIdentity:Int,
			environmentRevision:Int):Int {
		var result = targetHash;
		result = mix(result, states);
		result = mix(result, keyHash(parentKey));
		result = mix(result, themeIdentity);
		result = mix(result, themeRevision);
		result = mix(result, applicationIdentity);
		result = mix(result, applicationRevision);
		result = mix(result, keyHash(localKey));
		result = mix(result, environmentIdentity);
		return mix(result, environmentRevision);
	}

	function keyHash(value:String):Int {
		var cached = stringHashes.get(value);
		if (cached != null)
			return cached;
		if (stringHashCount >= MaxCacheEntries) {
			stringHashes.clear();
			stringHashCount = 0;
		}
		var result = stringHash(value);
		stringHashes.set(value, result);
		stringHashCount++;
		return result;
	}

	static function stringHash(value:String):Int {
		var result = 17;
		for (index in 0...value.length)
			result = mix(result, value.charCodeAt(index));
		return result;
	}

	static function stringKey(value:Null<String>):String
		return value == null ? "-1:" : value.length + ":" + value;

	function parentKey(parent:Null<ComputedStyle>):String {
		if (parent == null)
			return "none";
		var cached = parent.cachedInheritedKey();
		if (cached != null)
			return cached;
		var result = "";
		for (property in StyleProperty.all()) {
			if (!property.inherited)
				continue;
			result += property.name + "=" + (parent.has(property) ? "present:" : "absent:") +
				valueKey(property, parent.get(property)) +
				"@" + sourceKey(parent.source(property)) + ";";
		}
		parent.rememberInheritedKey(result);
		return result;
	}

	function localKey(local:Null<LayoutStyle>):String {
		if (local == null)
			return "none";
		var fingerprint = localFingerprint(local);
		var cached = localFingerprints.get(fingerprint);
		if (cached != null && sameLayoutStyle(local, cached.snapshot))
			return cached.key;
		var key = "local#" + nextLocalFingerprint++;
		if (localFingerprintCount >= MaxCacheEntries) {
			localFingerprints.clear();
			localFingerprintCount = 0;
		}
		localFingerprints.set(fingerprint, new StyleResolverLocalFingerprint(local.copy(), key));
		localFingerprintCount++;
		return key;
	}

	/** Every field, generated from LayoutStyle (haxeon.Structural), so a new field cannot be left out of the cache key. */
	static inline function localFingerprint(local:LayoutStyle):Int
		return haxeon.Structural.hash(local);

	static function colorFingerprint(seed:Int, value:Color):Int
		return mix(seed, value == null ? 0 : haxeon.Structural.hash(value));

	static inline function mix(seed:Int, value:Int):Int
		return seed * 31 + value;

	static inline function sameLayoutStyle(left:LayoutStyle, right:LayoutStyle):Bool
		return haxeon.Equality.equals(left, right);

	static function sourceKey(source:Null<StyleSource>):String
		return source == null ? "none" : stringKey(source.stylesheet) + "|" + stringKey(source.selector) +
			"|" + source.rule + "|" + stringKey(source.layer);

	static function valueKey<T>(property:StyleProperty<T>, value:T):String {
		if (value == null)
			return "null";
		return switch property.name {
			case "background" | "borderColor" | "outlineColor" | "shadowColor" |
				"textColor" | "progressTrackColor" | "progressFillColor" |
				"sliderTrackColor" | "sliderFillColor" | "sliderThumbColor":
				colorKey(cast value);
			case "width" | "height":
				axisKey(cast value);
			case "padding":
				insetsKey(cast value);
			case "transform":
				transformKey(cast value);
			case "effects" | "backdropEffects":
				var effects:EffectChain = cast value;
				effects == null ? "null" : effects.key();
			case "decorations":
				var decorations:DecorationChain = cast value;
				decorations == null ? "null" : decorations.key();
			case "mask":
				var mask:Mask = cast value;
				mask == null ? "null" : mask.describe();
			default:
				Std.string(value);
		};
	}

	static function colorKey(value:Color):String
		return value == null ? "null" : value.red + "," + value.green + "," + value.blue + "," + value.alpha;

	static function axisKey(value:LayoutAxis):String
		return value == null ? "null" : Std.string(value.sizing) + "," + value.value + "," +
			value.min + "," + value.max + "," + value.growWeight;

	static function insetsKey(value:Insets):String
		return value == null ? "null" : value.left + "," + value.top + "," + value.right + "," + value.bottom;

	static function transformKey(value:Transform2D):String
		return value == null ? "null" : value.a + "," + value.b + "," + value.c + "," +
			value.d + "," + value.tx + "," + value.ty;

	function applySheet(result:ComputedStyle, target:StyleTarget, sheet:Null<StyleSheet>,
			stateRules:Bool, layer:String, environment:Null<StyleEnvironment>):Void {
		if (sheet == null || sheet.isEmpty())
			return;
		var matches:Array<StyleRule> = [];
		for (rule in sheet.rules)
			if (rule.selector.hasState() == stateRules && rule.matches(target, environment))
				matches.push(rule);
		matches.sort(function(left, right) {
			var specificity = left.selector.specificity() - right.selector.specificity();
			return specificity == 0 ? left.order - right.order : specificity;
		});
		for (rule in matches) {
			var source = new StyleSource(sheet.name, rule.selector.describe(), rule.order, layer);
			result.recordMatch(source);
			for (declaration in rule.declarations)
				result.set(declaration.property, declaration.value, source);
		}
	}

	/** LayoutStyle's defaults, for applyLocal to find which fields a local style sets; never changed. */
	static final localDefaults:LayoutStyle = new LayoutStyle();
	/** The LayoutStyle fields the last applyLocal checked: every one, unless a new field has no style property yet. */
	public static var localFieldsHandled(default, null):Int = 0;

	function applyLocal(result:ComputedStyle, local:Null<LayoutStyle>):Void {
		if (local == null)
			return;
		var source = new StyleSource("local", "widget", -1, "local");
		var changed = haxeon.Structural.changedMask(local, localDefaults);
		// `handled` collects every field checked here, for localFieldsHandled.
		var handled = 0, bit = 0;
		bit = haxeon.Structural.fieldBit(LayoutStyle, "width");
		handled |= bit;
		if ((changed & bit) != 0)
			result.set(StyleProperty.Width, local.width, source);
		bit = haxeon.Structural.fieldBit(LayoutStyle, "height");
		handled |= bit;
		if ((changed & bit) != 0)
			result.set(StyleProperty.Height, local.height, source);
		bit = haxeon.Structural.fieldBit(LayoutStyle, "direction");
		handled |= bit;
		if ((changed & bit) != 0)
			result.set(StyleProperty.Direction, local.direction, source);
		bit = haxeon.Structural.fieldBit(LayoutStyle, "childAlignX");
		handled |= bit;
		if ((changed & bit) != 0)
			result.set(StyleProperty.ChildAlignX, local.childAlignX, source);
		bit = haxeon.Structural.fieldBit(LayoutStyle, "childAlignY");
		handled |= bit;
		if ((changed & bit) != 0)
			result.set(StyleProperty.ChildAlignY, local.childAlignY, source);
		bit = haxeon.Structural.fieldBit(LayoutStyle, "childDistribution");
		handled |= bit;
		if ((changed & bit) != 0)
			result.set(StyleProperty.ChildDistribution, local.childDistribution, source);
		bit = haxeon.Structural.fieldBit(LayoutStyle, "positioning");
		handled |= bit;
		if ((changed & bit) != 0)
			result.set(StyleProperty.Positioning, local.positioning, source);
		bit = haxeon.Structural.fieldBit(LayoutStyle, "aspectRatio");
		handled |= bit;
		if ((changed & bit) != 0)
			result.set(StyleProperty.AspectRatio, local.aspectRatio, source);
		bit = haxeon.Structural.fieldBit(LayoutStyle, "wrapMode");
		handled |= bit;
		if ((changed & bit) != 0)
			result.set(StyleProperty.WrapMode, local.wrapMode, source);
		bit = haxeon.Structural.fieldBit(LayoutStyle, "rowGap");
		handled |= bit;
		if ((changed & bit) != 0)
			result.set(StyleProperty.RowGap, local.rowGap, source);
		bit = haxeon.Structural.fieldBit(LayoutStyle, "columnGap");
		handled |= bit;
		if ((changed & bit) != 0)
			result.set(StyleProperty.ColumnGap, local.columnGap, source);
		bit = haxeon.Structural.fieldBit(LayoutStyle, "alignSelf");
		handled |= bit;
		if ((changed & bit) != 0)
			result.set(StyleProperty.AlignSelf, local.alignSelf, source);
		bit = haxeon.Structural.fieldBit(LayoutStyle, "positionX");
		handled |= bit;
		if ((changed & bit) != 0)
			result.set(StyleProperty.PositionX, local.positionX, source);
		bit = haxeon.Structural.fieldBit(LayoutStyle, "positionY");
		handled |= bit;
		if ((changed & bit) != 0)
			result.set(StyleProperty.PositionY, local.positionY, source);
		bit = haxeon.Structural.fieldBit(LayoutStyle, "zIndex");
		handled |= bit;
		if ((changed & bit) != 0)
			result.set(StyleProperty.ZIndex, local.zIndex, source);
		bit = haxeon.Structural.fieldBit(LayoutStyle, "overlay");
		handled |= bit;
		if ((changed & bit) != 0)
			result.set(StyleProperty.Overlay, local.overlay, source);
		bit = haxeon.Structural.fieldBit(LayoutStyle, "clipToParent");
		handled |= bit;
		if ((changed & bit) != 0)
			result.set(StyleProperty.ClipToParent, local.clipToParent, source);
		bit = haxeon.Structural.fieldBit(LayoutStyle, "padding");
		handled |= bit;
		if ((changed & bit) != 0)
			result.set(StyleProperty.Padding, local.padding, source);
		bit = haxeon.Structural.fieldBit(LayoutStyle, "childGap");
		handled |= bit;
		if ((changed & bit) != 0)
			result.set(StyleProperty.ChildGap, local.childGap, source);
		bit = haxeon.Structural.fieldBit(LayoutStyle, "background");
		handled |= bit;
		if ((changed & bit) != 0)
			result.set(StyleProperty.Background, local.background, source);
		bit = haxeon.Structural.fieldBit(LayoutStyle, "radiusTopLeft");
		handled |= bit;
		if ((changed & bit) != 0)
			result.set(StyleProperty.RadiusTopLeft, local.radiusTopLeft, source);
		bit = haxeon.Structural.fieldBit(LayoutStyle, "radiusTopRight");
		handled |= bit;
		if ((changed & bit) != 0)
			result.set(StyleProperty.RadiusTopRight, local.radiusTopRight, source);
		bit = haxeon.Structural.fieldBit(LayoutStyle, "radiusBottomRight");
		handled |= bit;
		if ((changed & bit) != 0)
			result.set(StyleProperty.RadiusBottomRight, local.radiusBottomRight, source);
		bit = haxeon.Structural.fieldBit(LayoutStyle, "radiusBottomLeft");
		handled |= bit;
		if ((changed & bit) != 0)
			result.set(StyleProperty.RadiusBottomLeft, local.radiusBottomLeft, source);
		bit = haxeon.Structural.fieldBit(LayoutStyle, "clipHorizontal");
		handled |= bit;
		if ((changed & bit) != 0)
			result.set(StyleProperty.ClipHorizontal, local.clipHorizontal, source);
		bit = haxeon.Structural.fieldBit(LayoutStyle, "clipVertical");
		handled |= bit;
		if ((changed & bit) != 0)
			result.set(StyleProperty.ClipVertical, local.clipVertical, source);
		bit = haxeon.Structural.fieldBit(LayoutStyle, "visible");
		handled |= bit;
		if ((changed & bit) != 0)
			result.set(StyleProperty.Visible, local.visible, source);
		bit = haxeon.Structural.fieldBit(LayoutStyle, "transform");
		handled |= bit;
		if ((changed & bit) != 0)
			result.set(StyleProperty.Transform, local.transform, source);
		bit = haxeon.Structural.fieldBit(LayoutStyle, "transformOriginX");
		handled |= bit;
		if ((changed & bit) != 0)
			result.set(StyleProperty.TransformOriginX, local.transformOriginX, source);
		bit = haxeon.Structural.fieldBit(LayoutStyle, "transformOriginY");
		handled |= bit;
		if ((changed & bit) != 0)
			result.set(StyleProperty.TransformOriginY, local.transformOriginY, source);
			localFieldsHandled = handled;
	}

	function applyTransitions(result:ComputedStyle, target:StyleTarget,
			theme:Null<StyleSheet>, application:Null<StyleSheet>):Void {
		if (scheduler == null)
			return;
		for (property in StyleProperty.all()) {
			var transition = transitionFor(property, theme, application);
			if (transition == null || property.interpolate == null || !result.has(property))
				continue;
			var key = animationKey(target, property);
			var next = result.get(property);
			var previousTarget = targets.get(key);
			if (!targets.exists(key)) {
				targets.set(key, next);
				animatedValues.set(key, next);
			} else if (!sameValue(property, previousTarget, next)) {
				targets.set(key, next);
				var current = animatedValues.get(key);
				stop(key);
				var animation = new StyleTransitionAnimation(current, next, transition.duration,
					transition.easing, property.name,
					function(value) { animatedValues.set(key, value); },
					function() { animatedValues.set(key, next); activeAnimations.remove(key); },
					property.interpolate == null ? null : cast property.interpolate);
				activeAnimations.set(key, animation);
				scheduler.track(animation);
			}
			if (animatedValues.exists(key))
				result.set(property, animatedValues.get(key), result.source(property));
		}
	}

	function transitionFor(property:StyleProperty<Dynamic>, theme:Null<StyleSheet>,
			application:Null<StyleSheet>):Null<StyleTransition> {
		var result = application == null ? null : application.transitionFor(property);
		return result == null && theme != null ? theme.transitionFor(property) : result;
	}

	function stop(key:String):Void {
		var active = activeAnimations.get(key);
		if (active != null && scheduler != null)
			scheduler.remove(active);
		activeAnimations.remove(key);
	}

	static function animationKey(target:StyleTarget, property:StyleProperty<Dynamic>):String {
		var identity = target.id != null ? target.id : target.key != null ? target.key : target.widgetType;
		return identity + "|" + property.name;
	}

	static function sameValue(property:StyleProperty<Dynamic>, left:Dynamic, right:Dynamic):Bool {
		if (left == right)
			return true;
		return property.isEqual(left, right);
	}
}

class StyleResolverLocalFingerprint {
	public final snapshot:LayoutStyle;
	public final key:String;

	public function new(snapshot:LayoutStyle, key:String) {
		this.snapshot = snapshot;
		this.key = key;
	}
}

/** Collision-checked structural key for a cached computed style. */
class StyleResolverCacheEntry {
	final target:StyleTarget;
	final states:Int;
	final parentKey:String;
	final themeIdentity:Int;
	final themeRevision:Int;
	final applicationIdentity:Int;
	final applicationRevision:Int;
	final localKey:String;
	final environmentIdentity:Int;
	final environmentRevision:Int;
	public final style:ComputedStyle;
	final localTextColor:Null<Color>;

	public function new(target:StyleTarget, states:Int, parentKey:String,
			themeIdentity:Int, themeRevision:Int, applicationIdentity:Int,
			applicationRevision:Int, localKey:String, environmentIdentity:Int,
			environmentRevision:Int, style:ComputedStyle, localTextColor:Null<Color>) {
		this.target = target;
		this.states = states;
		this.parentKey = parentKey;
		this.themeIdentity = themeIdentity;
		this.themeRevision = themeRevision;
		this.applicationIdentity = applicationIdentity;
		this.applicationRevision = applicationRevision;
		this.localKey = localKey;
		this.environmentIdentity = environmentIdentity;
		this.environmentRevision = environmentRevision;
		this.style = style;
		this.localTextColor = localTextColor;
	}

	public function matches(target:StyleTarget, states:Int, parentKey:String,
			themeIdentity:Int, themeRevision:Int, applicationIdentity:Int,
			applicationRevision:Int, localKey:String, environmentIdentity:Int,
			environmentRevision:Int, localTextColor:Null<Color>):Bool
		return this.target.sameSelector(target) && this.states == states &&
			this.parentKey == parentKey && this.themeIdentity == themeIdentity &&
			this.themeRevision == themeRevision &&
			this.applicationIdentity == applicationIdentity &&
			this.applicationRevision == applicationRevision && this.localKey == localKey &&
			this.environmentIdentity == environmentIdentity &&
			this.environmentRevision == environmentRevision &&
			StyleProperty.TextColor.isEqual(this.localTextColor, localTextColor);
}
