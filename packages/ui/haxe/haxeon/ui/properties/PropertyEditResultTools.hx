package haxeon.ui.properties;

/** Queries the case of a property edit result without comparing its payload. */
class PropertyEditResultTools {
	public static function isApplied(result:PropertyEditResult):Bool
		return switch result {
			case Applied: true;
			default: false;
		};
}
