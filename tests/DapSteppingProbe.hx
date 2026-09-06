function callee(input:Int):Int {
	var doubled = input * 2;
	var result = doubled + 1;
	return result;
}

function main():Int {
	Sys.sleep(1.0);
	var seed = 20;
	var answer = callee(seed);
	if (answer == 41) {
		answer = answer + 1;
	}
	for (index in 0...1) {
		answer = answer + index;
	}
	return answer;
}
