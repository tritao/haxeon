function main():Int {
    var outer = 0;
    var total = 0;
    while (outer < 6) {
        var inner = 0;
        while (inner < 7) {
            total = total + 1;
            inner = inner + 1;
        }
        outer = outer + 1;
    }
    return total * 2 / 2;
}
