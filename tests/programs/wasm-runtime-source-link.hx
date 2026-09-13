import runtime.FloatBits;
import runtime.RuntimeData;
import runtime.RyuTables;

function main():Int {
	var padded = StringTools.rpad("A", "bc", 5);
	var exponent = FloatBits.toInt64(1.0) >>> 52;
	var tableAddress = RyuTables.address();
	var tableShape = (RyuTables.INVERSE_ENTRIES + RyuTables.POWER_ENTRIES) * 4 == 2672;
	var firstInverseWord = RuntimeData.loadI32(tableAddress);
	var firstPowerHighWord = RuntimeData.loadI32(tableAddress + (RyuTables.INVERSE_ENTRIES * 4 + 3) * 4);
	return padded == "Abcbc"
		&& exponent == 1023
		&& tableShape
		&& firstInverseWord == 1
		&& firstPowerHighWord == 0x10000000 ? 42 : 0;
}
