function main():Int {
	var values = ["answer" => 42];
	return values.exists("answer") ? values["answer"] : 0;
}
