package runtime;

import runtime.RyuTableData;

/** Ryū's split-power table, stored as immutable module data rather than a runtime array. */
class RyuTables {
	public static inline final INVERSE_ENTRIES = 342;
	public static inline final POWER_ENTRIES = 326;

	static var tableAddress:Int = RyuTableData.address();

	public static function address():Int
		return tableAddress;
}
