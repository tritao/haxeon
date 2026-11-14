// Run the pinned host formatter with a checked writer, including in --check mode.
// The lexer is compiled from the same Haxe source used by the built-in formatter.
const fs = require('fs');
const path = require('path');

function checkedWriter(read, write, verify, check, changed) {
  return function (file, output, options) {
    const source = read(file, 'utf8');
    const formatted = Buffer.isBuffer(output) ? output.toString('utf8') : output;
    verify(String(file), source, formatted);
    if (check) {
      if (source !== formatted) changed(String(file));
      return;
    }
    return write(file, output, options);
  };
}

function main() {
  const guardPath = process.argv[2];
  const args = process.argv.slice(3);
  let check = false;
  const forwarded = [];
  for (let index = 0; index < args.length; index++) {
    if (args[index] === '--check') check = true;
    else if ((args[index] === '-s' || args[index] === '--source') && index + 1 < args.length)
      forwarded.push(args[index], args[++index]);
    else throw new Error(`Unsupported checked formatter argument: ${args[index]}`);
  }
  const verify = require(path.resolve(guardPath)).FormatterTokenGuard.verify;
  const read = fs.readFileSync.bind(fs);
  const write = fs.writeFileSync.bind(fs);
  const exit = process.exit.bind(process);
  let status = 0;
  const checked = checkedWriter(read, write, (file, source, formatted) => {
    try { verify(file, source, formatted); }
    catch (error) { status = 2; throw new Error(String(error)); }
  }, check, file => {
    console.log(`Incorrect formatting in ${file}`);
    if (status === 0) status = 1;
  });
  fs.writeFileSync = (...writeArgs) => {
    try { return checked(...writeArgs); }
    catch (error) {
      status = 2;
      console.error(String(error));
    }
  };
  process.exit = code => exit(status === 2 ? 2 : code || status);
  process.argv = [process.argv[0], path.resolve(__dirname, '../.tools/formatter/run.js'), ...forwarded];
  require('../.tools/formatter/run.js');
}

module.exports = {checkedWriter};
if (require.main === module) main();
