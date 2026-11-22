import fs from "node:fs";
import crypto from "node:crypto";
import os from "node:os";
import { performance } from "node:perf_hooks";

const [controlPath, candidatePath, sizeArg = "4096", roundsArg = "8", pairsArg = "9"] = process.argv.slice(2);
if (!controlPath || !candidatePath) throw Error("usage: node run.mjs control.wasm candidate.wasm [size rounds pairs]");
const size = Number(sizeArg), rounds = Number(roundsArg), pairs = Number(pairsArg);
if (![size, rounds, pairs].every(n => Number.isSafeInteger(n) && n > 0) || rounds % 2)
  throw Error("size and pairs must be positive integers; rounds must be positive and even");
const variants = Object.fromEntries([["control", controlPath], ["candidate", candidatePath]].map(([name, path]) => {
  const bytes = fs.readFileSync(path), exports = new WebAssembly.Instance(new WebAssembly.Module(bytes)).exports;
  if (typeof exports.__allocation_count !== "function") throw Error(`${name}: compile with --wasm-gc-allocation-count`);
  return [name, { exports, sha256: crypto.createHash("sha256").update(bytes).digest("hex") }];
}));
console.log(JSON.stringify({ node: process.version, cpu: os.cpus()[0]?.model, size, rounds, pairs, artifacts: Object.fromEntries(Object.entries(variants).map(([n, v]) => [n, v.sha256])) }));
let checksum = 0;
for (const operation of ["readRects", "writeRects", "reverseRects", "readTiny", "writeTiny", "reverseTiny"]) {
  const readings = { control: [], candidate: [] };
  for (const { exports } of Object.values(variants)) {
    exports["ArrayWordBench.prepare"](size);
    if (exports["ArrayWordBench.perform"]() !== 42) throw Error(`${operation}: preparation check failed`);
    for (let i = 0; i < 3; i++) checksum += exports[`ArrayWordBench.${operation}`](rounds);
  }
  for (let pair = 0; pair < pairs; pair++) {
    const results = {};
    for (const name of pair % 2 ? ["candidate", "control"] : ["control", "candidate"]) {
      const { exports } = variants[name], before = exports.__allocation_count(), start = performance.now();
      const result = exports[`ArrayWordBench.${operation}`](rounds), milliseconds = performance.now() - start;
      const allocations = exports.__allocation_count() - before;
      if (allocations !== 0) throw Error(`${operation}/${name}: ${allocations} allocations`);
      if (!Number.isFinite(result)) throw Error(`${operation}/${name}: non-finite checksum`);
      checksum += result; results[name] = result; readings[name].push(milliseconds);
      console.log(JSON.stringify({ operation, pair, version: name, milliseconds, allocations, result }));
    }
    if (results.control !== results.candidate) throw Error(`${operation}: control/candidate result mismatch`);
  }
  const median = xs => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)];
  const medians = Object.fromEntries(Object.entries(readings).map(([n, xs]) => [n, median(xs)]));
  console.log(JSON.stringify({ operation, medianMilliseconds: medians, speedup: medians.control / medians.candidate }));
}
console.log(JSON.stringify({ checksum }));
