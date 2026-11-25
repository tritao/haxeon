# The UI package's source roots and every module under them, for the scripts that call the compiler directly.
# Sourced with the package directory as its argument: `source "$module_dir/tools/ui-sources.sh" "$module_dir"`.
# Listing the modules by search keeps the scripts independent of how the package arranges its directories; every
# module is compiled, so one a program does not reach is still type-checked.

ui_source_roots=("$1/src")

ui_root_flags=()
for ui_root in "${ui_source_roots[@]}"; do
	ui_root_flags+=(--root="$ui_root")
done

ui_modules=()
while IFS= read -r ui_module; do
	ui_modules+=("$ui_module")
done < <(find "${ui_source_roots[@]}" -name '*.hx' | LC_ALL=C sort)
unset ui_root ui_module
