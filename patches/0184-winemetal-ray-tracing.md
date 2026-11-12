# 0184: winemetal ray tracing (Cycles on Metal)

Builds on 0183. Four calls and one compute command so a Windows program can build Metal acceleration structures and trace rays with them, unix-call slots **161-164**:

| Slot | Call | Does |
|---|---|---|
| 161 | `MTLDevice_accelerationStructureSizes` | sizes for a descriptor: the structure, the build scratch, the refit scratch |
| 162 | `MTLDevice_newAccelerationStructure` | an empty structure of that size (returns the handle and its gpuResourceID) |
| 163 | `MTLCommandBuffer_accelerationStructureCommandEncoder` | the build encoder |
| 164 | `MTLAccelerationStructureCommandEncoder_build` | builds a structure from a descriptor |

The descriptors cross as flat records (`WMTAccelInfo`, `WMTAccelTriangles` in winemetal.h), never as Metal objects: a primitive structure from triangle geometry (vertex and index buffers, opaque and
duplicate-intersection flags, intersection-function-table offset), or an instance structure from an instance descriptor buffer and the structures it refers to. New compute command
`WMTComputeCommandSetAccelerationStructure` (= 12) binds a structure at a buffer index. Local rendering only (the remote path answers STATUS_NOT_IMPLEMENTED).

Not in yet: curve/point (bounding box) geometry, motion blur, intersection function tables and linked functions, refit, compaction.

Checked on an M4 Mac with the same logic written natively (64 of 256 rays hit a quad, for the primitive and the instanced structure), and by `tools/spikes/cycles_metal/win/mtltest.cpp` through winemetal on a device.
