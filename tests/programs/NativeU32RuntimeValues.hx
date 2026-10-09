class TickValue {
	public var tick:UInt32;

	public function new(tick:UInt32) {
		this.tick = tick;
	}

	public function setCurrentTick(tick:UInt32):Void {
		this.tick = tick;
	}

	public function currentTick():UInt32 {
		return tick;
	}
}

function roundTripTick(tick:UInt32):UInt32 {
	return tick;
}

function roundTripTicks(ticks:Array<UInt32>):Array<UInt32> {
	return ticks;
}

function main():Int {
	var highBit:UInt32 = cast(-2147483648, UInt32);
	var allBits:UInt32 = cast(-1, UInt32);
	var value = new TickValue(highBit);
	value.setCurrentTick(allBits);
	var ticks:Array<UInt32> = roundTripTicks([value.currentTick(), highBit]);
	return roundTripTick(ticks[0]) == allBits && roundTripTick(ticks[1]) == highBit && ticks.indexOf(highBit) == 1 ? 42 : 1;
}
