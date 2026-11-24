const platforms = {linux: "linux", darwin: "mac", win32: "win"};
const directory = platforms[process.platform as keyof typeof platforms];
if (process.arch !== "x64" || !directory) {
  throw new Error("The bundled HashLink debugger requires x64 Linux, macOS, or Windows.");
}
module.exports = require(`./native/${directory}/hldebug.node`);
