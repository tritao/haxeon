# Event phases

`RenderNode.on(kind, handler, phase)` registers a listener for `capture`, `target`, or the default `bubble` phase.
Ordinary routed events visit ancestors in capture order from root toward the target, deliver at the target, then
bubble toward the root. A target's default listener participates in target delivery exactly once.

Focus, blur and focus-lost do **not** bubble. They visit capture listeners from root through the target, then deliver
once to the target's target/default listeners. A target capture listener runs only in capture; it is not invoked again
in target delivery. An ancestor's default listener is not invoked. `stopPropagation()` stops the remaining path;
`stopImmediatePropagation()` also stops the current node's remaining listeners.

A component wrapper observes descendant focus using a capture listener. Its child can then be replaced without
losing the wrapper's listener. Handlers see the original event target, their own `currentTarget`, and their phase.
The ancestor path is fixed before capture handlers run, including when a handler detaches a node.

Dispatch of an already constructed focus event allocates no objects or bytes, including traversal storage.
Event construction and listener registration precede that interval. `FocusCaptureMain` tests routing and
`FocusDispatchAllocations` measures dispatch through resolved, transformed nodes on HashLink, Wasm32 and Wasm GC,
with inlining both disabled and enabled.
