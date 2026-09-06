enum State {
	Ready;
}

function main():Int {
	var value = 40;
	var message = 'value=$value sum=${value + 2} state=${State.Ready} dollar=$';
	return message == "value=40 sum=42 state=Ready dollar=$" ? 42 : 0;
}
