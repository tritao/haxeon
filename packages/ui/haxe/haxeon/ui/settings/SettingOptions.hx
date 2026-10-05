package haxeon.ui.settings;

import haxeon.ui.properties.PropertyOption;

/** Optional presentation and validation policy for one setting. */
class SettingOptions {
	/** Row label; derived from the last path segment when null. */
	public var label:Null<String>;
	public var tooltip:Null<String>;
	public var minimum:Null<Float>;
	public var maximum:Null<Float>;
	public var step:Null<Float>;
	public var unit:Null<String>;
	/** Choices for an Enum setting. */
	public var options:Array<PropertyOption>;
	/** Hidden unless the settings dialog shows advanced settings. */
	public var advanced:Bool;
	/** Takes effect only after the application restarts. */
	public var restartRequired:Bool;
	/** Saved like any other setting but never shown in the settings dialog. */
	public var internal:Bool;

	public function new() {
		label = null;
		tooltip = null;
		minimum = null;
		maximum = null;
		step = null;
		unit = null;
		options = [];
		advanced = false;
		restartRequired = false;
		internal = false;
	}
}
