import Retained;

class RetainedHolder {
	public var point:retained_point;

	public function new() {
		point = new retained_point();
	}
}

function main():Int {
	var holder = new RetainedHolder();
	var index = 0;
	while (index < 10000) {
		holder.point.set_x(index);
		holder.point.set_y(index + 1);
		var transient = [
			index,
			index + 1,
			index + 2,
			index + 3,
			index + 4,
			index + 5,
			index + 6,
			index + 7
		];
		if (transient[0] != index || Retained.check(holder.point) != index + index + 1)
			return 1;
		index = index + 1;
	}
	return 42;
}
