#!/usr/bin/env python3
"""Where a compile's peak memory is set: resident memory by phase, collections and heap censuses.

    scripts/peak-timeline.py [--log FILE] [NAME=VALUE...] -- COMMAND...

Runs COMMAND (a compiler run on HashLink, e.g. `out/cmake/release/hashlink-runtime/hl compiler.hl --entry=...`) with
HAXEON_PEAK_MARKS and HL_GC_TIMELINE set, samples its resident memory every 10 ms, and prints each compiler phase mark
and collection with the resident memory at that moment, then the peak. NAME=VALUE pairs are added to its environment:

    HAXEON_PEAK_CENSUS=ir-done   heap census at a phase mark (collects first): live bytes by type, owner and root path
    HAXEON_PEAK_CENSUS=all       ... at every mark (with HL_GC_CENSUS_NOGC=1: pages per size class, without collecting)
    HL_GC_CENSUS_AT=2            census inside the second collection, right after its mark: what it keeps
    HL_GC_CENSUS_TOP=40          entries per list

The census lines (`census ...`) and the command's own output go to the log (--log, default peak-timeline.log). A census
is slow and allocates outside the heap, so read the resident memory of a run without one.
"""
import os
import subprocess
import sys
import tempfile
import time


def main(argv):
	log_path = "peak-timeline.log"
	env = dict(os.environ)
	if "--" not in argv:
		sys.exit(__doc__)
	split = argv.index("--")
	options, command = argv[:split], argv[split + 1:]
	index = 0
	while index < len(options):
		if options[index] == "--log":
			log_path = options[index + 1]
			index += 2
			continue
		name, value = options[index].split("=", 1)
		env[name] = value
		index += 1
	if not command:
		sys.exit(__doc__)
	timeline = tempfile.NamedTemporaryFile(prefix="peak-gc-", suffix=".tl", delete=False).name
	env["HAXEON_PEAK_MARKS"] = "1"
	env["HL_GC_TIMELINE"] = timeline
	wall0, mono0 = time.time(), time.monotonic()
	with open(log_path, "w") as log:
		process = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT)
		samples = []
		while process.poll() is None:
			try:
				with open("/proc/%d/status" % process.pid) as status:
					for line in status:
						if line.startswith("VmRSS"):
							samples.append((time.monotonic(), int(line.split()[1]) // 1024))
			except OSError:
				pass
			time.sleep(0.01)
	if not samples:
		sys.exit("no samples: /proc is needed")

	def resident_at(moment):
		best = None
		for sampled, resident in samples:
			if sampled <= moment:
				best = resident
		return best

	events = []
	with open(log_path, errors="replace") as log:
		for line in log:
			if line.startswith("mark "):
				parts = line.split()
				if len(parts) == 3:
					events.append((float(parts[2]) - wall0 + mono0, "mark " + parts[1]))
	try:
		with open(timeline) as pauses:
			for line in pauses:
				if line[0] in "Ss":
					events.append((int(line.split()[1]) / 1e9, "collection " + ("starts" if line[0] == "S" else "ends")))
	finally:
		os.unlink(timeline)
	for moment, name in sorted(events):
		print("%7.2fs %-36s resident %s MB" % (moment - mono0, name, resident_at(moment)))
	peak = max(samples, key=lambda sample: sample[1])
	print("peak %d MB at %.2fs, wall %.2fs, exit %d, log %s" % (peak[1], peak[0] - mono0, samples[-1][0] - mono0,
		process.returncode, log_path))
	return process.returncode


if __name__ == "__main__":
	sys.exit(main(sys.argv[1:]))
