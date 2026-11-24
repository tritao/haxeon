const fs = require("node:fs");

const moduleBytes = fs.readFileSync("build/wasm32/main.wasm");
const decoder = new TextDecoder();
const instance = new WebAssembly.Instance(new WebAssembly.Module(moduleBytes), {
  haxeon_host: {
    print(pointer) {
      const memory = new Uint8Array(instance.exports.memory.buffer);
      const end = memory.indexOf(0, pointer);
      process.stdout.write(decoder.decode(memory.subarray(pointer, end)));
    },
  },
});
instance.exports.main();
