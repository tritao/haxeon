class Operations {
	static inline final FIRST = 1;
	static inline final SECOND = 2;

	public static function apply(operation:Int):Int
		return switch operation {
			case FIRST: 1;
			case SECOND: 42;
			default: 0;
		};
}

function main():Int
	return Operations.apply(2);
