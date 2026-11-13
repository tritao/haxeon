# Event phases

`UiEvent.phase` is the closed `UiEventPhase` enum: `Capture`, `Target`, or `Bubble`.
`RenderNode.on(kind, handler, phase)` takes that enum and defaults to `UiEventPhase.Bubble`.
Ordinary routed events visit ancestors in capture order from root toward the target, deliver at the target, then
bubble toward the root. A target's default listener participates in target delivery exactly once.

Focus, blur and focus-lost do **not** bubble. They visit capture listeners from root through the target, then deliver
once to the target's target/default listeners. A target capture listener runs only in capture; it is not invoked again
in target delivery. An ancestor's default listener is not invoked. `stopPropagation()` stops the remaining path;
`stopImmediatePropagation()` also stops the current node's remaining listeners.

An ancestor observes descendant focus using a capture listener. Components use their body root as their node
identity; they do not introduce a wrapper for event routing. Handlers see the original event target, their own
`currentTarget`, and their phase.
The ancestor path is fixed before capture handlers run, including when a handler detaches a node.

Dispatch of an already constructed focus event allocates no objects or bytes, including traversal storage.
Event construction and listener registration precede that interval. `FocusCaptureMain` tests routing and
`FocusDispatchAllocations` measures dispatch through resolved, transformed nodes on HashLink, Wasm32 and Wasm GC,
with inlining both disabled and enabled.

Outside-pointer notifications use their separate subscription list and direct `Target` delivery. They retain the
original pointer target and set `currentTarget` to the subscribed node; they do not traverse capture or bubble listeners.
The internal target-only bubble listener policy selects listeners; it is not another event phase.
