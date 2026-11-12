// The Metal layer (winemetal) built natively for macOS (DXMT_NATIVE), tested through its real C API: the same calls a Windows program makes, including the Porthole additions
// (patches 0183-0185). See run.sh. Everything Cycles' Metal device needs from the layer should be testable here on the Mac before it runs on a device.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <chrono>
#include "winemetal.h"

static int failures = 0;
static void check(bool ok, const char *what) { printf("%s %s\n", ok ? "ok  " : "FAIL", what); if (!ok) failures++; }
static double now() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }

static std::string text_of(obj_handle_t s) {
  if (!s) return "";
  uint64_t n = NSString_lengthOfBytesUsingEncoding(s, WMTUTF8StringEncoding);
  std::string out(n + 1, '\0'); NSString_getCString(s, &out[0], n + 1, WMTUTF8StringEncoding); out.resize(strlen(out.c_str())); return out;
}

static obj_handle_t g_device, g_queue;
static obj_handle_t shared_buffer(size_t bytes, void **memory) {
  bytes = (bytes + 16383) & ~(size_t)16383;
  void *m = nullptr; posix_memalign(&m, 16384, bytes); memset(m, 0, bytes);
  WMTBufferInfo bi{}; bi.length = bytes; bi.options = WMTResourceStorageModeShared; bi.memory.ptr = m;
  *memory = m; return MTLDevice_newBuffer(g_device, &bi);
}
static obj_handle_t library(const std::string &src, std::string *error = nullptr) {
  obj_handle_t err = 0;
  obj_handle_t lib = MTLDevice_newLibraryWithSource(g_device, src.data(), src.size(), 0x0302, WMT_LIBRARY_FLAG_FAST_MATH, &err);
  if (error) *error = err ? text_of(NSObject_description(err)) : "";
  if (err) NSObject_release(err);
  return lib;
}
static obj_handle_t build(const WMTAccelInfo &info) {
  WMTAccelSizes sizes{}; MTLDevice_accelerationStructureSizes(g_device, &info, &sizes);
  uint64_t rid = 0; obj_handle_t as = MTLDevice_newAccelerationStructure(g_device, sizes.structure_size, &rid);
  WMTBufferInfo sbi{}; sbi.length = sizes.build_scratch_size ? sizes.build_scratch_size : 16; sbi.options = WMTResourceStorageModePrivate;
  obj_handle_t scratch = MTLDevice_newBuffer(g_device, &sbi);
  obj_handle_t cb = MTLCommandQueue_commandBuffer(g_queue), enc = MTLCommandBuffer_accelerationStructureCommandEncoder(cb);
  MTLAccelerationStructureCommandEncoder_build(enc, as, &info, scratch, 0);
  MTLCommandEncoder_endEncoding(enc); MTLCommandBuffer_commit(cb); MTLCommandBuffer_waitUntilCompleted(cb);
  return MTLCommandBuffer_status(cb) == WMTCommandBufferStatusCompleted && rid ? as : 0;
}
// bind, optionally a table, run 256 threads writing into out
static bool run(obj_handle_t pso, obj_handle_t structure, obj_handle_t table, obj_handle_t extra_use, obj_handle_t out, uint8_t out_index) {
  obj_handle_t cb = MTLCommandQueue_commandBuffer(g_queue), enc = MTLCommandBuffer_computeCommandEncoder(cb, false);
  wmtcmd_compute_setpso c1{}; c1.type = WMTComputeCommandSetPSO; c1.pso = pso; c1.threadgroup_size = {64, 1, 1};
  wmtcmd_compute_setaccel c2{}; c2.type = WMTComputeCommandSetAccelerationStructure; c2.accel = structure; c2.index = 0;
  wmtcmd_compute_setift c3{}; c3.type = WMTComputeCommandSetIntersectionFunctionTable; c3.table = table; c3.index = 1;
  wmtcmd_compute_useresource c4{}; c4.type = WMTComputeCommandUseResource; c4.resource = structure; c4.usage = WMTResourceUsageRead;
  wmtcmd_compute_useresource c5{}; c5.type = WMTComputeCommandUseResource; c5.resource = extra_use ? extra_use : structure; c5.usage = WMTResourceUsageRead;
  wmtcmd_compute_setbuffer c6{}; c6.type = WMTComputeCommandSetBuffer; c6.buffer = out; c6.offset = 0; c6.index = out_index;
  wmtcmd_compute_dispatch c7{}; c7.type = WMTComputeCommandDispatchThreads; c7.size = {256, 1, 1};
  wmtcmd_base *head = (wmtcmd_base *)&c1; c1.next.ptr = &c2;
  c2.next.ptr = table ? (void *)&c3 : (void *)&c4; c3.next.ptr = &c4; c4.next.ptr = &c5; c5.next.ptr = &c6; c6.next.ptr = &c7;
  MTLComputeCommandEncoder_encodeCommands(enc, head); MTLCommandEncoder_endEncoding(enc);
  MTLCommandBuffer_commit(cb); MTLCommandBuffer_waitUntilCompleted(cb);
  return MTLCommandBuffer_status(cb) == WMTCommandBufferStatusCompleted;
}
static void count(const float *o, int *hits, int *misses, int *wrong) {
  *hits = *misses = *wrong = 0;
  for (int k = 0; k < 256; k++) { if (o[k] > 4.99f && o[k] < 5.01f) (*hits)++; else if (o[k] == -1.0f) (*misses)++; else (*wrong)++; }
}

int main(int argc, char **argv) {
  obj_handle_t devices = WMTCopyAllDevices();
  g_device = NSArray_object(devices, 0); g_queue = MTLDevice_newCommandQueue(g_device, 16);
  printf("device: %s\n", text_of(MTLDevice_name(g_device)).c_str());

  // 1. zero-copy compute
  {
    std::string err; obj_handle_t lib = library("#include <metal_stdlib>\nusing namespace metal;\nkernel void add1(device float *a [[buffer(0)]], uint i [[thread_position_in_grid]]) { a[i] += 1.0f; }\n", &err);
    check(lib != 0, "small kernel library compiles from source");
    void *mem; obj_handle_t buf = shared_buffer(1 << 20, &mem); float *f = (float *)mem; for (int i = 0; i < 262144; i++) f[i] = (float)i;
    WMTComputePipelineInfo pi{}; pi.compute_function = MTLLibrary_newFunction(lib, "add1"); obj_handle_t perr = 0;
    obj_handle_t pso = MTLDevice_newComputePipelineState(g_device, &pi, &perr);
    obj_handle_t cb = MTLCommandQueue_commandBuffer(g_queue), enc = MTLCommandBuffer_computeCommandEncoder(cb, false);
    wmtcmd_compute_setpso c1{}; c1.type = WMTComputeCommandSetPSO; c1.pso = pso; c1.threadgroup_size = {256, 1, 1};
    wmtcmd_compute_setbuffer c2{}; c2.type = WMTComputeCommandSetBuffer; c2.buffer = buf; c2.index = 0;
    wmtcmd_compute_dispatch c3{}; c3.type = WMTComputeCommandDispatchThreads; c3.size = {262144, 1, 1};
    c1.next.ptr = &c2; c2.next.ptr = &c3;
    MTLComputeCommandEncoder_encodeCommands(enc, (wmtcmd_base *)&c1); MTLCommandEncoder_endEncoding(enc); MTLCommandBuffer_commit(cb); MTLCommandBuffer_waitUntilCompleted(cb);
    bool ok = true; for (int i = 0; i < 262144; i++) if (f[i] != (float)i + 1.0f) { ok = false; break; }
    check(ok, "a buffer around the program's own memory is changed in place by the GPU");
  }

  // 2. ray tracing: a quad, then one instance of it moved 10 to the right
  void *vm, *im, *om, *dm; obj_handle_t vb = shared_buffer(65536, &vm), ib = shared_buffer(65536, &im), ob = shared_buffer(65536, &om), db = shared_buffer(65536, &dm);
  const float quad[] = {-1, -1, 5, 1, -1, 5, 1, 1, 5, -1, 1, 5}; memcpy(vm, quad, sizeof quad);
  const uint32_t tri[] = {0, 1, 2, 0, 2, 3}; memcpy(im, tri, sizeof tri);
  WMTAccelTriangles g{}; g.vertex_buffer = vb; g.vertex_stride = 12; g.index_buffer = ib; g.index_type = 1; g.triangle_count = 2; g.flags = 1;
  WMTAccelInfo blasinfo{}; blasinfo.kind = WMT_ACCEL_KIND_PRIMITIVE; blasinfo.count = 1; blasinfo.geometries = (uint64_t)(uintptr_t)&g;
  obj_handle_t blas = build(blasinfo); check(blas != 0, "bottom level structure builds");
  uint8_t *inst = (uint8_t *)dm; float tr[12] = {1, 0, 0, 0, 1, 0, 0, 0, 1, 10, 0, 0}; memcpy(inst, tr, 48); uint32_t tail[4] = {0, 0xff, 0, 0}; memcpy(inst + 48, tail, 16);
  obj_handle_t list[1] = {blas};
  WMTAccelInfo tlasinfo{}; tlasinfo.kind = WMT_ACCEL_KIND_INSTANCE; tlasinfo.count = 1; tlasinfo.instance_buffer = db; tlasinfo.instanced_structures = (uint64_t)(uintptr_t)list; tlasinfo.instanced_count = 1;
  tlasinfo.use_resources = (uint64_t)(uintptr_t)list; tlasinfo.use_count = 1;
  obj_handle_t tlas = blas ? build(tlasinfo) : 0; check(tlas != 0, "top level structure (one instance) builds");

  std::string err;
  obj_handle_t rt = library(
      "#include <metal_stdlib>\n#include <metal_raytracing>\nusing namespace metal; using namespace raytracing;\n"
      "kernel void trace_prim(primitive_acceleration_structure as [[buffer(0)]], device float *out [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
      "  float x = -2.0f + 4.0f * (float(i % 16) + 0.5f) / 16.0f, y = -2.0f + 4.0f * (float(i / 16) + 0.5f) / 16.0f;\n"
      "  ray r; r.origin = float3(x, y, 0); r.direction = float3(0, 0, 1); r.min_distance = 0.001f; r.max_distance = 100.0f;\n"
      "  intersector<triangle_data> isect; intersection_result<triangle_data> res = isect.intersect(r, as);\n"
      "  out[i] = res.type == intersection_type::triangle ? res.distance : -1.0f; }\n"
      "kernel void trace_inst(instance_acceleration_structure as [[buffer(0)]], device float *out [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
      "  float x = 8.0f + 4.0f * (float(i % 16) + 0.5f) / 16.0f, y = -2.0f + 4.0f * (float(i / 16) + 0.5f) / 16.0f;\n"
      "  ray r; r.origin = float3(x, y, 0); r.direction = float3(0, 0, 1); r.min_distance = 0.001f; r.max_distance = 100.0f;\n"
      "  intersector<triangle_data, instancing> isect; intersection_result<triangle_data, instancing> res = isect.intersect(r, as);\n"
      "  out[i] = res.type == intersection_type::triangle ? res.distance : -1.0f; }\n", &err);
  check(rt != 0, "ray tracing kernels compile");
  for (int pass = 0; pass < 2 && rt; pass++) {
    WMTComputePipelineInfo pi{}; pi.compute_function = MTLLibrary_newFunction(rt, pass ? "trace_inst" : "trace_prim"); obj_handle_t perr = 0;
    obj_handle_t pso = MTLDevice_newComputePipelineState(g_device, &pi, &perr);
    float *o = (float *)om; for (int k = 0; k < 256; k++) o[k] = -99.0f;
    bool done = run(pso, pass ? tlas : blas, 0, blas, ob, 1);
    int h, m, w; count(o, &h, &m, &w);
    check(done && h == 64 && m == 192 && w == 0, pass ? "rays traced against the instanced structure: 64 hit, 192 missed" : "rays traced against the bottom level structure: 64 hit, 192 missed");
  }

  // 3. a custom intersection function in a table
  WMTAccelTriangles g2 = g; g2.flags = 0; WMTAccelInfo b2{}; b2.kind = WMT_ACCEL_KIND_PRIMITIVE; b2.count = 1; b2.geometries = (uint64_t)(uintptr_t)&g2;
  obj_handle_t blas2 = build(b2);
  obj_handle_t il = library(
      "#include <metal_stdlib>\n#include <metal_raytracing>\nusing namespace metal; using namespace raytracing;\n"
      "[[intersection(triangle, triangle_data)]] bool accept_right(float3 origin [[origin]]) { return origin.x > 0.0f; }\n"
      "kernel void trace_ift(primitive_acceleration_structure as [[buffer(0)]], intersection_function_table<triangle_data> ift [[buffer(1)]], device float *out [[buffer(2)]], uint i [[thread_position_in_grid]]) {\n"
      "  float x = -2.0f + 4.0f * (float(i % 16) + 0.5f) / 16.0f, y = -2.0f + 4.0f * (float(i / 16) + 0.5f) / 16.0f;\n"
      "  ray r; r.origin = float3(x, y, 0); r.direction = float3(0, 0, 1); r.min_distance = 0.001f; r.max_distance = 100.0f;\n"
      "  intersector<triangle_data> isect; intersection_result<triangle_data> res = isect.intersect(r, as, ift);\n"
      "  out[i] = res.type == intersection_type::triangle ? res.distance : -1.0f; }\n", &err);
  check(il != 0 && blas2 != 0, "intersection function kernels compile; non-opaque structure builds");
  if (il && blas2) {
    obj_handle_t kfn = MTLLibrary_newFunction(il, "trace_ift"), afn = MTLLibrary_newFunction(il, "accept_right"), linked[1] = {afn};
    WMTComputePipelineInfoEx pe{}; pe.compute_function = kfn; pe.linked_functions = (uint64_t)(uintptr_t)linked; pe.linked_count = 1; pe.max_call_stack_depth = 2;
    obj_handle_t perr = 0, pso = MTLDevice_newComputePipelineStateEx(g_device, &pe, &perr);
    check(pso != 0, "pipeline with a linked function");
    uint64_t rid = 0; obj_handle_t table = pso ? MTLComputePipelineState_newIntersectionFunctionTable(pso, 1, &rid) : 0;
    obj_handle_t fh = table ? MTLComputePipelineState_functionHandle(pso, afn) : 0;
    if (table && fh) MTLIntersectionFunctionTable_setFunction(table, fh, 0);
    check(table && fh && rid, "intersection function table, function handle and resource id");
    float *o = (float *)om; for (int k = 0; k < 256; k++) o[k] = -99.0f;
    bool done = table && run(pso, blas2, table, table, ob, 2);
    int h, m, w; count(o, &h, &m, &w);
    check(done && h == 32 && m == 224 && w == 0, "a custom intersection function accepted 32 rays and rejected 224");
  }

  // 4. Cycles' own kernel, if a source file is given
  if (argc > 1) {
    FILE *f = fopen(argv[1], "rb"); if (f) {
      fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET); std::string body(n, '\0'); fread(&body[0], 1, n, f); fclose(f);
      std::string src = std::string("#define __KERNEL_METAL_APPLE__\n#define __METAL_GLOBAL_BUILTINS__\n#define __KERNEL_METAL_MACOS__ 27\n#define __KERNEL_METAL_TARGET_CPU_ARM64__\n#define __KERNEL_METALRT__\n") + body;
      double t0 = now(); obj_handle_t cl = library(src, &err);
      check(cl != 0, "Cycles' kernel source (with ray tracing) compiles"); printf("     %.1f s %s\n", now() - t0, err.substr(0, 300).c_str());
    }
  }
  printf("%s\n", failures ? "SOME CHECKS FAILED" : "ALL CHECKS PASSED");
  return failures ? 1 : 0;
}
