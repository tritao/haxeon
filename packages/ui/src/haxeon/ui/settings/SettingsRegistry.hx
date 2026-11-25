package haxeon.ui.settings;

import haxeon.ui.properties.PropertyType;
import haxeon.ui.properties.PropertyValue;
import haxeon.ui.properties.PropertyValueTools;

/**
 * Every setting the application knows about, in definition order.
 *
 * Each module defines the settings it reads, next to the code that reads them.
 * Defining the same path again with the same type and default returns the
 * first definition, so modules can share a setting; any other redefinition is
 * a programming error.
 */
class SettingsRegistry {
	final byPath:Map<String, SettingDefinition>;
	final ordered:Array<SettingDefinition>;

	public function new() {
		byPath = new Map();
		ordered = [];
	}

	public function define(path:String, type:PropertyType, defaultValue:PropertyValue,
			?settings:SettingOptions):SettingDefinition
		return add(new SettingDefinition(path, type, defaultValue, settings));

	public function add(definition:SettingDefinition):SettingDefinition {
		if (definition == null)
			throw "Setting definition cannot be null";
		var existing = byPath.get(definition.path);
		if (existing != null) {
			if (!sameType(existing.type, definition.type)
				|| !PropertyValueTools.same(existing.defaultValue, definition.defaultValue))
				throw 'Setting "${definition.path}" is already defined with a different type or default';
			return existing;
		}
		for (other in ordered)
			if (StringTools.startsWith(other.path, definition.path + "/")
				|| StringTools.startsWith(definition.path, other.path + "/"))
				throw 'Setting "${definition.path}" cannot share a path prefix with "${other.path}"';
		byPath.set(definition.path, definition);
		ordered.push(definition);
		return definition;
	}

	public function get(path:String):Null<SettingDefinition>
		return byPath.get(path);

	public function exists(path:String):Bool
		return byPath.exists(path);

	/** All definitions in definition order. */
	public function all():Array<SettingDefinition>
		return ordered.copy();

	/** Definitions at or below the prefix, in definition order. An empty prefix matches everything. */
	public function under(prefix:String):Array<SettingDefinition> {
		var result:Array<SettingDefinition> = [];
		for (definition in ordered)
			if (SettingsRegistry.covers(prefix, definition.path))
				result.push(definition);
		return result;
	}

	/** Whether a path is the prefix itself or lies below it, segment-wise. */
	public static function covers(prefix:String, path:String):Bool
		return prefix == null || prefix.length == 0 || path == prefix || StringTools.startsWith(path, prefix + "/");

	static function sameType(first:PropertyType, second:PropertyType):Bool
		return switch ([first, second]) {
			case [PropertyType.Bool, PropertyType.Bool] | [PropertyType.Int, PropertyType.Int]
				| [PropertyType.Float, PropertyType.Float] | [PropertyType.Text, PropertyType.Text]
				| [PropertyType.Enum, PropertyType.Enum]: true;
			default: false;
		};
}
