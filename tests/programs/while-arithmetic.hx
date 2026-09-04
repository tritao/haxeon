function ping():Int {
    return 1;
}

function main():Int {
    var value = 6 * 8;
    while (value < 0) {
        ping();
    }
    ping();
    return value - 12 / 2;
}
