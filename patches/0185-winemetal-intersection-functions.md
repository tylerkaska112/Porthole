# 0185: winemetal compute pipelines with linked functions, and intersection function tables (Cycles on Metal)

Builds on 0183 and 0184. Unix-call slots **165-169** and one compute command:

| Slot | Call | Does |
|---|---|---|
| 165 | `MTLDevice_newComputePipelineStateEx` | a compute pipeline with linked functions (intersection functions the kernel may call), a call stack depth, a thread limit and immutable-buffer flags (`WMTComputePipelineInfoEx`; the old `WMTComputePipelineInfo` stays as it is) |
| 166 | `MTLComputePipelineState_newIntersectionFunctionTable` | a table for a pipeline (returns the handle and its gpuResourceID) |
| 167 | `MTLComputePipelineState_functionHandle` | the handle of a linked function in that pipeline |
| 168 | `MTLIntersectionFunctionTable_setFunction` | puts a function handle in a table slot |
| 169 | `MTLIntersectionFunctionTable_setBuffer` | binds a buffer for the table's functions (Cycles binds its launch parameters) |

New compute command `WMTComputeCommandSetIntersectionFunctionTable` (= 13) binds a table at a buffer index. Local rendering only.

Checked on an M4 Mac with the same logic written natively (a function that accepts a hit only for rays starting right of the middle: 32 of 256 rays hit a quad), and by `tools/spikes/cycles_metal/win/mtltest.cpp` through winemetal on a device.
