package haxeon.ui.settings;

import haxeon.ui.properties.PropertyDescriptor;
import haxeon.ui.properties.PropertyDescriptorOptions;
import haxeon.ui.properties.PropertyInspectorSection;
import haxeon.ui.properties.PropertyValue;

/**
 * How the settings dialog organizes a registry.
 *
 * A setting's first two path segments name its category in the tree
 * ("interface/editor"); a two-segment path files under its first segment.
 * Segments between the category and the name group rows into sections
 * ("fonts" in "interface/editor/fonts/main_font_size"). Settings without a
 * section come first, under the category's own label.
 */
class SettingsCatalog {
	public final store:SettingsStore;
	final descriptors:Map<String, PropertyDescriptor>;

	public function new(store:SettingsStore) {
		if (store == null)
			throw "Settings catalogs require a store";
		this.store = store;
		descriptors = new Map();
	}

	public static function categoryOf(definition:SettingDefinition):String {
		var segments = definition.segments;
		return segments.length <= 2 ? segments[0] : segments[0] + "/" + segments[1];
	}

	/** The section path between category and name, or "" for none. */
	public static function sectionOf(definition:SettingDefinition):String {
		var segments = definition.segments;
		return segments.length <= 3 ? "" : segments.slice(2, segments.length - 1).join("/");
	}

	/** "interface/editor" becomes "Editor"; "text_editor" becomes "Text Editor". */
	public static function labelOf(path:String):String {
		var segments = path.split("/");
		return SettingDefinition.labelFor(segments[segments.length - 1]);
	}

	/**
	 * Whether the dialog lists the setting. Internal settings never show;
	 * advanced ones only when asked for, or when the filter names them. The
	 * filter matches the label or path, ignoring case.
	 */
	public static function visible(definition:SettingDefinition, filter:String, showAdvanced:Bool):Bool {
		if (definition.internal)
			return false;
		var text = filter == null ? "" : StringTools.trim(filter).toLowerCase();
		if (text.length == 0)
			return showAdvanced || !definition.advanced;
		return definition.label.toLowerCase().indexOf(text) >= 0
			|| definition.path.indexOf(text.split(" ").join("_")) >= 0;
	}

	/** Categories that hold a visible setting, in definition order. */
	public function categories(filter:String, showAdvanced:Bool):Array<String> {
		var result:Array<String> = [];
		for (definition in store.registry.all()) {
			var category = categoryOf(definition);
			if (visible(definition, filter, showAdvanced) && result.indexOf(category) < 0)
				result.push(category);
		}
		return result;
	}

	/** The category's visible settings as inspector sections: unsectioned first, then in definition order. */
	public function sections(category:String, filter:String, showAdvanced:Bool):Array<PropertyInspectorSection> {
		var order:Array<String> = [];
		var grouped:Map<String, Array<PropertyDescriptor>> = new Map();
		for (definition in store.registry.all()) {
			if (categoryOf(definition) != category || !visible(definition, filter, showAdvanced))
				continue;
			var section = sectionOf(definition);
			if (!grouped.exists(section)) {
				var rows:Array<PropertyDescriptor> = [];
				grouped.set(section, rows);
				if (section.length == 0)
					order.unshift(section);
				else
					order.push(section);
			}
			grouped.get(section).push(descriptor(definition));
		}
		var result:Array<PropertyInspectorSection> = [];
		for (section in order) {
			var label = section.length == 0 ? labelOf(category) : [for (part in section.split("/")) SettingDefinition.labelFor(part)].join(" › ");
			result.push(new PropertyInspectorSection(section.length == 0 ? category : category + "/" + section, label,
				grouped.get(section)));
		}
		return result;
	}

	/**
	 * The inspector row for a setting, reused across calls so editors keep their
	 * state. Edits go straight to the store, outside undo history.
	 */
	public function descriptor(definition:SettingDefinition):PropertyDescriptor {
		var existing = descriptors.get(definition.path);
		if (existing != null)
			return existing;
		var options = new PropertyDescriptorOptions();
		options.category = categoryOf(definition);
		options.recordHistory = false;
		options.minimum = definition.minimum;
		options.maximum = definition.maximum;
		options.step = definition.step;
		options.unit = definition.unit;
		options.defaultValue = definition.defaultValue;
		options.options = definition.options;
		options.validator = function(_, value) return definition.validate(value);
		var target = store;
		var path = definition.path;
		var created = new PropertyDescriptor(path, definition.restartRequired ? definition.label + " *" : definition.label,
			definition.type, function(_) return target.get(path), function(_, value:PropertyValue) {
				var error = target.set(path, value);
				if (error != null)
					throw error;
			}, options);
		descriptors.set(path, created);
		return created;
	}
}
