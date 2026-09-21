#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
	echo "usage: replace-in-file.sh <sed-expression> <file>" >&2
	exit 2
fi

expression=$1
file=$2
temporary=$(mktemp "${file}.XXXXXX")
trap 'rm -f "$temporary"' EXIT

sed "$expression" "$file" > "$temporary"
mv "$temporary" "$file"
trap - EXIT
