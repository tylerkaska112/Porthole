# 0186: winemetal pipeline limits and threadgroup memory (Cycles on Metal)

Builds on 0183-0185. Unix-call slot **170** `MTLComputePipelineState_limits` (a pipeline's `maxTotalThreadsPerThreadgroup`, `threadExecutionWidth` and `staticThreadgroupMemoryLength`) and the compute command
`WMTComputeCommandSetThreadgroupMemoryLength` (= 14). Cycles sizes its threadgroups from the limits and gives its path-sorting kernels threadgroup memory through the command. Local rendering only.
