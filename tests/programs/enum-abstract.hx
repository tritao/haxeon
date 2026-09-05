enum abstract ExitCode(Int) from Int to Int {
	var Answer = 42;
}

function main():Int {
	return ExitCode.Answer;
}
