package haxeon.ui.settings;

import haxe.Json;
import haxe.io.Path;
import haxeon.ui.properties.PropertyType;
import haxeon.ui.properties.PropertyValue;
import haxeon.ui.properties.PropertyValueTools;
import sys.FileSystem;
import sys.io.File;

/**
 * Current setting values over the registry's defaults, saved as JSON.
 *
 * Only values that differ from their default are kept and saved, so changing
 * a default in code reaches everyone who never touched that setting. Saved
 * values whose setting is not defined in this build are kept and written back
 * unchanged, because another build or a module that loads later may define
 * them. A saved value that no longer fits its setting falls back to the
 * default. Every change saves at once unless it happens inside batch().
 *
 * The same file also keeps application state that is not a setting, such as
 * recently opened files: JSON-compatible values under a key, never shown in
 * the settings dialog and never validated.
 */
class SettingsStore {
	public static inline var FORMAT_VERSION:Int = 1;

	public final registry:SettingsRegistry;
	/** Where values are saved; null keeps them in memory only. */
	public final file:Null<String>;
	/** Increases on every change, for views that cache what they show. */
	public var revision(default, null):Int;
	/** Why the last load or save failed, or null when it worked. */
	public var lastError(default, null):Null<String>;

	final overrides:Map<String, PropertyValue>;
	final unknown:Map<String, Dynamic>;
	final state:Map<String, Dynamic>;
	final listeners:Array<SettingsListener>;
	var batchDepth:Int;
	var dirty:Bool;

	public function new(registry:SettingsRegistry, ?file:String) {
		if (registry == null)
			throw "Settings stores require a registry";
		this.registry = registry;
		this.file = file;
		revision = 0;
		lastError = null;
		overrides = new Map();
		unknown = new Map();
		state = new Map();
		listeners = [];
		batchDepth = 0;
		dirty = false;
		if (file != null)
			load();
	}

	public function get(path:String):PropertyValue {
		var definition = require(path);
		adopt(definition);
		var value = overrides.get(path);
		return value == null ? definition.defaultValue : value;
	}

	public function getBool(path:String):Bool
		return switch (get(path)) {
			case Bool(value): value;
			default: throw 'Setting "$path" is not a Bool';
		};

	public function getInt(path:String):Int
		return switch (get(path)) {
			case Int(value): value;
			default: throw 'Setting "$path" is not an Int';
		};

	public function getFloat(path:String):Float
		return switch (get(path)) {
			case Float(value): value;
			default: throw 'Setting "$path" is not a Float';
		};

	/** The text of a Text setting or the option key of an Enum setting. */
	public function getString(path:String):String
		return switch (get(path)) {
			case Text(value) | Enum(value): value;
			default: throw 'Setting "$path" is not Text or Enum';
		};

	/** Stores the value and returns null, or returns why it was refused and leaves the setting alone. */
	public function set(path:String, value:PropertyValue):Null<String> {
		var definition = require(path);
		var error = definition.validate(value);
		if (error != null)
			return error;
		adopt(definition);
		var normalized = definition.normalize(value);
		var previous = get(path);
		if (PropertyValueTools.same(previous, normalized))
			return null;
		if (PropertyValueTools.same(definition.defaultValue, normalized))
			overrides.remove(path);
		else
			overrides.set(path, normalized);
		changed(path);
		return null;
	}

	public function reset(path:String):Void {
		var definition = require(path);
		adopt(definition);
		if (overrides.remove(path))
			changed(path);
	}

	/** Resets every setting at or below the prefix. */
	public function resetUnder(prefix:String):Void
		batch(function() {
			for (definition in registry.under(prefix))
				reset(definition.path);
		});

	public function isDefault(path:String):Bool {
		adopt(require(path));
		return !overrides.exists(path);
	}

	/**
	 * Calls the listener with the path of every setting that changes at or
	 * below the prefix; an empty prefix hears every change. Returns a function
	 * that removes the listener.
	 */
	public function onChanged(prefix:String, listener:String->Void):Void->Void {
		if (listener == null)
			throw "Settings listeners cannot be null";
		var entry = new SettingsListener(prefix == null ? "" : prefix, listener);
		listeners.push(entry);
		return function() listeners.remove(entry);
	}

	/** Application state saved under the key, or null. */
	public function getState(key:String):Dynamic
		return state.get(key);

	/** Saves JSON-compatible application state under the key; null removes it. Listeners are not told. */
	public function setState(key:String, value:Dynamic):Void {
		if (key == null || key.length == 0)
			throw "State keys cannot be empty";
		if (value == null)
			state.remove(key);
		else
			state.set(key, value);
		dirty = true;
		if (batchDepth == 0)
			save();
	}

	/** Runs the work and saves once at the end instead of after every change. */
	public function batch(work:Void->Void):Void {
		batchDepth++;
		try {
			work();
		} catch (error:Dynamic) {
			batchDepth--;
			if (batchDepth == 0 && dirty)
				save();
			throw error;
		}
		batchDepth--;
		if (batchDepth == 0 && dirty)
			save();
	}

	/**
	 * Writes every changed value, plus saved values this build does not
	 * define, through a temporary file so a crash never leaves half a file.
	 * Returns false (and sets lastError) when writing fails; settings are a
	 * convenience, so failing to save must not disturb the caller.
	 */
	public function save():Bool {
		dirty = false;
		if (file == null)
			return true;
		var values:Dynamic = {};
		for (path in sortedKeys(unknown))
			Reflect.setField(values, path, unknown.get(path));
		for (path in sortedKeys(overrides))
			Reflect.setField(values, path, encode(overrides.get(path)));
		var saved:Dynamic = {};
		for (key in sortedKeys(state))
			Reflect.setField(saved, key, state.get(key));
		var temporary = file + ".tmp";
		try {
			createDirectories(Path.directory(file));
			File.saveContent(temporary, Json.stringify({version: FORMAT_VERSION, values: values, state: saved}, null, "\t"));
			FileSystem.rename(temporary, file);
			lastError = null;
			return true;
		} catch (error:Dynamic) {
			lastError = 'Could not save settings to "$file": $error';
			return false;
		}
	}

	/** Paths of every saved value this build does not define. */
	public function unknownPaths():Array<String>
		return sortedKeys(unknown);

	function load():Void {
		if (!FileSystem.exists(file))
			return;
		try {
			var raw:Dynamic = Json.parse(File.getContent(file));
			var values:Dynamic = raw == null ? null : Reflect.field(raw, "values");
			if (values == null || !Reflect.isObject(values) || SettingsJsonValue.isArray(values))
				throw "missing \"values\" object";
			for (path in Reflect.fields(values))
				unknown.set(path, Reflect.field(values, path));
			var saved:Dynamic = Reflect.field(raw, "state");
			if (saved != null && Reflect.isObject(saved) && !SettingsJsonValue.isArray(saved))
				for (key in Reflect.fields(saved))
					state.set(key, Reflect.field(saved, key));
		} catch (error:Dynamic) {
			// A damaged file only resets these conveniences; the next save replaces it.
			lastError = 'Could not read settings from "$file": $error';
		}
	}

	/** Decodes a saved value once its setting is defined; a value that no longer fits is dropped. */
	function adopt(definition:SettingDefinition):Void {
		if (!unknown.exists(definition.path))
			return;
		var decoded = decode(definition, unknown.get(definition.path));
		unknown.remove(definition.path);
		if (decoded != null && definition.validate(decoded) == null
			&& !PropertyValueTools.same(definition.defaultValue, definition.normalize(decoded)))
			overrides.set(definition.path, definition.normalize(decoded));
	}

	function changed(path:String):Void {
		revision++;
		dirty = true;
		for (entry in listeners.copy())
			if (SettingsRegistry.covers(entry.prefix, path))
				entry.listener(path);
		if (batchDepth == 0)
			save();
	}

	function require(path:String):SettingDefinition {
		var definition = registry.get(path);
		if (definition == null)
			throw 'Unknown setting "$path"';
		return definition;
	}

	static function decode(definition:SettingDefinition, raw:Dynamic):Null<PropertyValue> {
		if (raw == null)
			return null;
		if (SettingsJsonValue.isBool(raw))
			return PropertyValue.Bool(raw);
		if (SettingsJsonValue.isInt(raw))
			return PropertyValue.Int(raw);
		if (SettingsJsonValue.isFloat(raw))
			return PropertyValue.Float(raw);
		if (SettingsJsonValue.isString(raw))
			return switch (definition.type) {
				case PropertyType.Enum: PropertyValue.Enum(raw);
				default: PropertyValue.Text(raw);
			};
		return null;
	}

	static function encode(value:PropertyValue):Dynamic
		return switch (value) {
			case Bool(data): data;
			case Int(data): data;
			case Float(data): data;
			case Text(data) | Enum(data): data;
			default: null;
		};

	static function sortedKeys<T>(map:Map<String, T>):Array<String> {
		var keys = [for (key in map.keys()) key];
		keys.sort(function(first, second) return Reflect.compare(first, second));
		return keys;
	}

	static function createDirectories(directory:String):Void {
		if (directory == null || directory.length == 0 || FileSystem.exists(directory))
			return;
		createDirectories(Path.directory(directory));
		FileSystem.createDirectory(directory);
	}
}

private class SettingsListener {
	public final prefix:String;
	public final listener:String->Void;

	public function new(prefix:String, listener:String->Void) {
		this.prefix = prefix;
		this.listener = listener;
	}
}
