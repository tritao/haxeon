const fs = require("fs");
const vm = require("vm");
vm.runInThisContext(fs.readFileSync("stdlib/haxeon/wasm/haxeon-host.js", "utf8"));

(async () => {
  const memory = new WebAssembly.Memory({initial: 32});
  const live = new Set();
  let cursor = 65536, allocations = 0;
  const guest = new WebAssembly.Module(fs.readFileSync(process.argv[2]));
  const {exports, unavailable} = await HaxeonWasmHost.instantiate(guest, {
    memory,
    allocate: size => {
      const address = cursor;
      cursor += Math.ceil(size / 16) * 16;
      live.add(address);
      allocations++;
      return address;
    },
    release: address => {
      if (!live.delete(address)) throw new Error("Arena released an allocation twice");
    }
  });
  const result = exports.main();
  if (unavailable.length || result !== 42 || allocations !== 2 || live.size)
    throw new Error(JSON.stringify({result, allocations, live: live.size, unavailable}));
  console.log("PASS: native arena stores, growth, reset and disposal through the Wasm host");
})().catch(error => { console.error(error); process.exit(1); });
