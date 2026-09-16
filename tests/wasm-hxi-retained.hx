import Retained;

class RetainedHolder {
	public var point:retained_point;
	public var label:retained_label;
	public var options:retained_options;
	public var container:retained_container;

	public function new() {
		point = new retained_point();
		label = new retained_label();
		label.set_value("retained-" + 42);
		options = makeOptions();
		container = makeContainer();
	}
}

function makeOptions():retained_options {
	var first = new retained_point();
	first.set_x(10);
	first.set_y(11);
	var second = new retained_point();
	second.set_x(20);
	second.set_y(21);
	var options = new retained_options();
	options.set_points([first, second]);
	options.set_paths(["alpha", "βeta"]);
	options.set_data_bytes(haxe.io.Bytes.ofString("payload"));
	return options;
}

function makeContainer():retained_container {
	var options = makeOptions();
	var container = new retained_container();
	container.set_value(options);
	container.set_options([options]);
	return container;
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
		if (transient[0] != index
			|| Retained.check(holder.point) != index + index + 1
			|| Retained.check_label(holder.label) != 42
			|| Retained.check_options(holder.options) != 42
			|| Retained.check_container(holder.container, holder.container.get_value()) != 42
			|| Retained.check_paths(["alpha", "βeta"]) != 42)
			return 1;
		index = index + 1;
	}
	return 42;
}
