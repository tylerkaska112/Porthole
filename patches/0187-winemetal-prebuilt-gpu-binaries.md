# 0187: winemetal loads GPU binaries built ahead of time (Cycles on Metal)

Builds on 0183-0186. Unix-call slot **171** `MTLDevice_setBinaryArchive(device, bytes, length, arch_out, err_out)`: loads a Metal binary archive (the file `metal-tt` writes for one GPU architecture) from memory and keeps it as the
archive that pipelines use, and reports the device's architecture name (`applegpu_g16p`, ...). Flag **bit 1** of `WMTComputePipelineInfoEx.flags` (slot 165) builds the pipeline from that archive with
`MTLPipelineOptionFailOnBinaryArchiveMiss`: a miss returns no pipeline and starts no compile.

Why: the biggest Cycles kernels kill the system's Metal compiler service on a phone or iPad (XPC_ERROR_CONNECTION_INTERRUPTED, and nothing compiles afterwards), while Apple's offline tools build the same kernels in
seconds on a Mac. Local rendering only. Games are unaffected: a new table entry and a flag nothing else sets.
