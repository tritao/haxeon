# Reactive ID reservation measurements

On 2026-11-04, the editor at outer `f1a9e9516` and Haxeon `f0c3d377` was run on HashLink with 12 cycles per
scenario. A temporary instrument in the isolated editor checkout sampled the last reserved ID at each completed
frame and subtracted its own one-ID probe. A sample covers the input, frame and intervening harness work since the
previous probe; it is not an exclusive attribution inside the UI. Setup with no previous frame is excluded. Primitive
operations were sampled around 5,000 executions after warmup; their values are per operation. These are IDs reserved,
not the number of source objects: Observable sources reserve the program-wide field stride.

| Scenario | Action | Samples | Median IDs | Maximum IDs |
| --- | --- | ---: | ---: | ---: |
| interaction | hover-away | 12 | 0 | 0 |
| interaction | hover-enter | 12 | 0 | 0 |
| interaction | hover-field | 12 | 0 | 0 |
| interaction | hover-inside | 12 | 0 | 0 |
| interaction | hover-other | 12 | 0 | 0 |
| interaction | idle | 12 | 0 | 0 |
| interaction | idle-focused | 12 | 0 | 0 |
| interaction | scroll-inspector | 12 | 0 | 0 |
| interaction | setup:focus | 1 | 0 | 0 |
| interaction | setup:inspector | 1 | 0 | 0 |
| interaction | type-backspace | 12 | 0 | 0 |
| interaction | type-char | 12 | 0 | 0 |
| interaction | verify:rebuild | 2 | 343 | 343 |
| tab-matrix | console->telemetry | 12 | 0 | 346 |
| tab-matrix | hierarchy->sensors | 12 | 0 | 924 |
| tab-matrix | sensors->hierarchy | 12 | 0 | 0 |
| tab-matrix | setup:console | 12 | 0 | 0 |
| tab-matrix | setup:hierarchy | 11 | 0 | 0 |
| tab-matrix | telemetry->console | 12 | 0 | 0 |
| dock-drag | drag:down | 1 | 0 | 0 |
| dock-drag | drag:move | 8 | 0 | 0 |
| dock-drag | drag:settle | 1 | 0 | 0 |
| dock-drag | drag:up | 1 | 347 | 347 |
| dock-drag | warm:console | 1 | 0 | 0 |
| dock-drag | warm:hierarchy | 1 | 0 | 0 |
| dock-drag | warm:sensors | 1 | 0 | 0 |
| dock-drag | warm:settle | 1 | 0 | 0 |
| dock-drag | warm:telemetry | 1 | 0 | 0 |
| inspector-edits | property-invalid | 12 | 3 | 3 |
| inspector-edits | property-position | 12 | 1 | 115 |
| inspector-edits | property-visible | 12 | 115 | 115 |
| inspector-edits | selection | 11 | 1564 | 1564 |
| inspector-edits | setup:inspector | 1 | 0 | 0 |
| inspector-flows | cancel-sketch | 12 | 0 | 0 |
| inspector-flows | create-part | 12 | 1551 | 1552 |
| inspector-flows | create-sketch | 12 | 0 | 3 |
| inspector-flows | select-box | 12 | 2 | 2 |
| inspector-flows | setup:inspector | 1 | 0 | 0 |
| panel-flows | bim-add-property | 12 | 799 | 799 |
| panel-flows | bim-collapse | 12 | 685 | 685 |
| panel-flows | bim-expand | 12 | 687 | 687 |
| panel-flows | bim-instance-label | 12 | 799 | 799 |
| panel-flows | bim-instance-override | 12 | 114 | 114 |
| panel-flows | bim-layout-restored | 1 | 378 | 378 |
| panel-flows | bim-property-schema | 12 | 689 | 689 |
| panel-flows | bim-redo | 12 | 685 | 685 |
| panel-flows | bim-remove-property | 12 | 457 | 457 |
| panel-flows | bim-rename | 12 | 799 | 799 |
| panel-flows | bim-resize | 12 | 685 | 685 |
| panel-flows | bim-select-instance | 12 | 717 | 717 |
| panel-flows | bim-select-project | 12 | 705 | 705 |
| panel-flows | bim-select-type | 12 | 722 | 1178 |
| panel-flows | bim-settled | 12 | 0 | 0 |
| panel-flows | bim-spatial | 12 | 726 | 726 |
| panel-flows | bim-type-default | 12 | 114 | 114 |
| panel-flows | bim-type-restore | 12 | 0 | 0 |
| panel-flows | bim-types | 12 | 22 | 374 |
| panel-flows | bim-unchanged | 12 | 0 | 0 |
| panel-flows | bim-undo | 12 | 685 | 685 |
| panel-flows | camera-disclosure | 12 | 0 | 0 |
| panel-flows | camera-geometry-settled | 12 | 0 | 0 |
| panel-flows | camera-live-paint | 12 | 0 | 0 |
| panel-flows | camera-no-assembly | 12 | 0 | 0 |
| panel-flows | camera-no-host | 12 | 0 | 0 |
| panel-flows | camera-overlay | 12 | 4 | 22 |
| panel-flows | camera-public-remount | 12 | 0 | 0 |
| panel-flows | camera-redock-settled | 12 | 0 | 0 |
| panel-flows | camera-redocked | 12 | 5 | 5 |
| panel-flows | camera-remounted-paint | 12 | 0 | 0 |
| panel-flows | camera-unchanged | 12 | 0 | 0 |
| panel-flows | camera-view-label | 12 | 0 | 0 |
| panel-flows | camera-zoom | 12 | 0 | 0 |
| panel-flows | cnc-cleared | 12 | 0 | 0 |
| panel-flows | cnc-empty | 1 | 1982 | 1982 |
| panel-flows | cnc-hidden | 12 | 0 | 504 |
| panel-flows | cnc-hold | 12 | 1 | 1 |
| panel-flows | cnc-prepared | 12 | 117 | 119 |
| panel-flows | cnc-preview | 12 | 578 | 579 |
| panel-flows | cnc-progress | 6588 | 0 | 1 |
| panel-flows | cnc-reset | 12 | 1 | 1 |
| panel-flows | cnc-resume | 12 | 1 | 1 |
| panel-flows | cnc-returned | 12 | 1 | 1 |
| panel-flows | cnc-select | 12 | 1 | 1 |
| panel-flows | cnc-source | 12 | 2 | 2 |
| panel-flows | cnc-speed | 12 | 1 | 1 |
| panel-flows | cnc-stopping | 48 | 0 | 1 |
| panel-flows | cnc-unchanged | 12 | 0 | 0 |
| panel-flows | machine-angle-down | 12 | 0 | 0 |
| panel-flows | machine-angle-key | 12 | 114 | 114 |
| panel-flows | machine-angle-move | 12 | 114 | 228 |
| panel-flows | machine-angle-up | 12 | 114 | 114 |
| panel-flows | machine-detents | 12 | 114 | 114 |
| panel-flows | machine-draft | 24 | 114 | 114 |
| panel-flows | machine-enter | 24 | 114 | 114 |
| panel-flows | machine-external-cancel | 12 | 114 | 114 |
| panel-flows | machine-external-preview | 12 | 114 | 228 |
| panel-flows | machine-free | 12 | 114 | 114 |
| panel-flows | machine-gesture-before-lock | 12 | 114 | 114 |
| panel-flows | machine-initial | 1 | 2000 | 2000 |
| panel-flows | machine-locked | 12 | 114 | 114 |
| panel-flows | machine-redo | 12 | 114 | 114 |
| panel-flows | machine-replaced | 12 | 684 | 684 |
| panel-flows | machine-save-pose | 12 | 114 | 114 |
| panel-flows | machine-slider-down | 12 | 114 | 114 |
| panel-flows | machine-slider-move | 12 | 114 | 114 |
| panel-flows | machine-slider-up | 12 | 114 | 114 |
| panel-flows | machine-unchanged | 12 | 0 | 0 |
| panel-flows | machine-undo | 12 | 114 | 114 |
| panel-flows | machine-unlocked | 12 | 114 | 114 |
| panel-flows | mission-authored | 12 | 7 | 123 |
| panel-flows | mission-cleared | 12 | 0 | 0 |
| panel-flows | mission-empty | 1 | 1981 | 1981 |
| panel-flows | mission-failure-reset | 12 | 1 | 1 |
| panel-flows | mission-follow | 12 | 2 | 2 |
| panel-flows | mission-manual-scroll | 12 | 2 | 2 |
| panel-flows | mission-prepared | 12 | 230 | 230 |
| panel-flows | mission-program | 12 | 0 | 1 |
| panel-flows | mission-progress | 288 | 1 | 2 |
| panel-flows | mission-replaced | 12 | 572 | 572 |
| panel-flows | mission-reset | 12 | 2 | 2 |
| panel-flows | mission-select | 12 | 2 | 2 |
| panel-flows | mission-timeout | 12 | 116 | 116 |
| panel-flows | mission-unchanged | 12 | 0 | 0 |
| panel-flows | project-failure | 1 | 0 | 0 |
| panel-flows | project-no-failure | 1 | 4 | 4 |
| panel-flows | show:bim | 2 | 4768 | 5436 |
| panel-flows | show:inspection-camera | 14 | 0 | 4794 |
| panel-flows | show:project | 1 | 116 | 116 |
| panel-flows | show:sensors | 24 | 0 | 0 |
| panel-flows | show:start | 12 | 0 | 469 |
| panel-flows | show:telemetry | 1 | 346 | 346 |
| panel-flows | start-category | 12 | 114 | 114 |
| panel-flows | start-category-all | 12 | 114 | 114 |
| panel-flows | start-failure | 12 | 114 | 114 |
| panel-flows | start-no-failure | 12 | 118 | 118 |
| panel-flows | start-recent | 12 | 114 | 228 |
| panel-flows | start-recent-gone | 12 | 114 | 114 |
| panel-flows | start-search | 12 | 114 | 228 |
| panel-flows | start-search-cleared | 12 | 114 | 114 |
| panel-flows | start-startup-off | 12 | 114 | 114 |
| panel-flows | start-startup-on | 12 | 114 | 114 |
| panel-flows | start-unchanged | 12 | 114 | 114 |
| panel-flows | telemetry-step | 36 | 0 | 0 |
| selection-stress | selection | 12 | 2 | 1564 |
| selection-stress | setup:inspector | 1 | 0 | 0 |
| tab-inspector | hierarchy | 12 | 0 | 0 |
| tab-inspector | inspector-focus | 1 | 0 | 0 |
| tab-inspector | rename | 1 | 1 | 1 |
| tab-inspector | sensors | 12 | 0 | 924 |
| primitives | beginFrame | 5000 | 0 | — |
| primitives | withScope(Key) empty | 5000 | 0 | — |
| primitives | scope + id | 5000 | 0 | — |
| primitives | new WidgetId | 5000 | 0 | — |
| primitives | new RenderNode | 5000 | 0 | — |
| primitives | new StyleTarget | 5000 | 0 | — |
| primitives | resolve (cache hit) | 5000 | 0 | — |
| primitives | computed.toLayoutStyle | 5000 | 0 | — |
| primitives | new LayoutStyle | 5000 | 0 | — |
| primitives | new Semantics | 5000 | 0 | — |
| primitives | Text widget build | 5000 | 0 | — |
| primitives | Button widget build | 5000 | 0 | — |
| primitives | resolveTextRole | 5000 | 0 | — |
