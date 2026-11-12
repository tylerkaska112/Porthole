// Windows-side test of the Metal layer (winemetal.dll) for Cycles on Metal. A native Arm (aarch64) program: add it to Porthole as a game and start it; the result lines go to the log.
// 1. the device; 2. a Metal buffer around this program's own memory (no copy) written by a kernel; 3. Cycles' real Metal kernel source compiled by MTLDevice_newLibraryWithSource
//    (the new call, slot 160) and a compute pipeline built from it. Needs a Porthole whose winemetal unix side has slot 160 (1.3.35 and later).
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winternl.h>
#include <stdio.h>
#include <string.h>
#include <string>
#include <chrono>
#include <stdarg.h>
#include "winemetal.h"

static HMODULE g_metal;
#define API(name) static decltype(&name) p_##name = (decltype(&name))GetProcAddress(g_metal, #name)

static double now() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }

typedef LONG(WINAPI *UnixCall)(unsigned long long handle, unsigned int code, void *args);
struct NewLibrarySource {   // = struct unixcall_mtldevice_newlibrarysource (winemetal_thunks.h)
  obj_handle_t device; uint64_t source; uint64_t source_len; uint32_t language_version; uint32_t flags; obj_handle_t ret_error; obj_handle_t ret_library;
};


// ---- a window that shows what the test is doing (the same lines also go to the log)
static HWND g_window, g_edit;
static double g_start;
static volatile LONG g_finished;
static void say(const char *fmt, ...) {
  char line[4096]; va_list ap; va_start(ap, fmt); vsnprintf(line, sizeof line, fmt, ap); va_end(ap);
  fputs(line, stdout);
  // the edit control wants \r\n; the text is handed to the window thread, which owns the control
  std::string text; for (const char *c = line; *c; c++) { if (*c == '\n') text += '\r'; text += *c; }
  if (g_window) { std::string *copy = new std::string(text); PostMessageA(g_window, WM_APP, 0, (LPARAM)copy); }
}
static LRESULT CALLBACK window_proc(HWND w, UINT m, WPARAM wp, LPARAM lp) {
  switch (m) {
    case WM_CREATE:
      g_edit = CreateWindowExA(WS_EX_CLIENTEDGE, "EDIT", "", WS_CHILD | WS_VISIBLE | WS_VSCROLL | ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL, 0, 0, 10, 10, w, nullptr, nullptr, nullptr);
      SendMessageA(g_edit, WM_SETFONT, (WPARAM)GetStockObject(ANSI_FIXED_FONT), TRUE);
      SetTimer(w, 1, 500, nullptr);
      return 0;
    case WM_SIZE: MoveWindow(g_edit, 0, 0, LOWORD(lp), HIWORD(lp), TRUE); return 0;
    case WM_TIMER: {
      char title[128]; snprintf(title, sizeof title, "Metal test - %s - %.0f s", g_finished ? "done" : "running, keep Porthole in front", now() - g_start);
      SetWindowTextA(w, title); return 0;
    }
    case WM_APP: {
      std::string *t = (std::string *)lp;
      SendMessageA(g_edit, EM_SETSEL, (WPARAM)-1, (LPARAM)-1); SendMessageA(g_edit, EM_REPLACESEL, FALSE, (LPARAM)t->c_str());
      delete t; return 0;
    }
    case WM_DESTROY: PostQuitMessage(0); return 0;
  }
  return DefWindowProcA(w, m, wp, lp);
}

static std::string text_of(obj_handle_t nsstring) {
  static auto getC = (decltype(&NSString_getCString))GetProcAddress(g_metal, "NSString_getCString");
  static auto len = (decltype(&NSString_lengthOfBytesUsingEncoding))GetProcAddress(g_metal, "NSString_lengthOfBytesUsingEncoding");
  if (!nsstring) return "";
  uint64_t n = len(nsstring, WMTUTF8StringEncoding);
  std::string s(n + 1, '\0');
  getC(nsstring, &s[0], n + 1, WMTUTF8StringEncoding);
  s.resize(strlen(s.c_str()));
  return s;
}

static DWORD WINAPI run_tests(LPVOID) {
  setvbuf(stdout, nullptr, _IONBF, 0);
  g_metal = LoadLibraryA("winemetal.dll");
  say("RESULT winemetal.dll: %s\n", g_metal ? "loaded" : "NOT FOUND");
  if (!g_metal) return 1;
  API(WMTCopyAllDevices); API(NSArray_count); API(NSArray_object); API(MTLDevice_name); API(NSObject_release); API(NSObject_description);
  API(MTLDevice_newCommandQueue); API(MTLCommandQueue_commandBuffer); API(MTLCommandBuffer_computeCommandEncoder); API(MTLComputeCommandEncoder_encodeCommands);
  API(MTLCommandEncoder_endEncoding); API(MTLCommandBuffer_commit); API(MTLCommandBuffer_waitUntilCompleted); API(MTLCommandBuffer_status);
  API(MTLDevice_newBuffer); API(MTLLibrary_newFunction); API(MTLDevice_newComputePipelineState);

  obj_handle_t devices = p_WMTCopyAllDevices();
  obj_handle_t device = p_NSArray_count(devices) ? p_NSArray_object(devices, 0) : 0;
  say("RESULT device: %s\n", text_of(p_MTLDevice_name(device)).c_str());
  if (!device) return 1;

  // the unix-side call table of winemetal.dll
  typedef NTSTATUS(NTAPI * QueryVM)(HANDLE, LPCVOID, int, PVOID, SIZE_T, SIZE_T *);
  HMODULE nt = GetModuleHandleA("ntdll.dll");
  QueryVM query = (QueryVM)GetProcAddress(nt, "NtQueryVirtualMemory");
  UnixCall *dispatcher = (UnixCall *)GetProcAddress(nt, "__wine_unix_call_dispatcher");
  unsigned long long handle = 0;
  NTSTATUS st = query(GetCurrentProcess(), g_metal, 1000 /* MemoryWineLoadUnixLib */, &handle, sizeof handle, nullptr);
  say("RESULT unix call table: status 0x%lx handle 0x%llx dispatcher %p\n", (unsigned long)st, handle, dispatcher ? (void *)*dispatcher : nullptr);
  if (!dispatcher || !*dispatcher) return 1;
  auto compile = [&](const std::string &src, uint32_t version, obj_handle_t *err_out) -> obj_handle_t {
    NewLibrarySource p{}; p.device = device; p.source = (uint64_t)(uintptr_t)src.data(); p.source_len = src.size(); p.language_version = version; p.flags = 1;
    LONG r = (*dispatcher)(handle, 160, &p);
    if (r) { say("RESULT slot 160 refused: status 0x%lx (an older Porthole has no such call)\n", (unsigned long)r); return 0; }
    *err_out = p.ret_error; return p.ret_library;
  };
  auto error_text = [&](obj_handle_t err) { return err ? text_of(p_NSObject_description(err)) : std::string(); };

  obj_handle_t queue = p_MTLDevice_newCommandQueue(device, 16);

  // ---- 1. a kernel that adds 1 to every float of a buffer that lives in THIS program's memory
  {
    obj_handle_t err = 0;
    obj_handle_t lib = compile("#include <metal_stdlib>\nusing namespace metal;\nkernel void add1(device float *a [[buffer(0)]], uint i [[thread_position_in_grid]]) { a[i] += 1.0f; }\n", 0x0302, &err);
    say("RESULT small kernel library: %s %s\n", lib ? "OK" : "FAILED", error_text(err).substr(0, 300).c_str());
    if (lib) {
      obj_handle_t fn = p_MTLLibrary_newFunction(lib, "add1");
      WMTComputePipelineInfo pi{}; pi.compute_function = fn; obj_handle_t perr = 0;
      obj_handle_t pso = p_MTLDevice_newComputePipelineState(device, &pi, &perr);
      const size_t n = 1 << 20, bytes = n * 4;
      float *mem = (float *)VirtualAlloc(nullptr, bytes, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
      for (size_t i = 0; i < n; i++) mem[i] = (float)i;
      WMTBufferInfo bi{}; bi.length = bytes; bi.options = WMTResourceStorageModeShared; bi.memory.ptr = mem;
      obj_handle_t buffer = p_MTLDevice_newBuffer(device, &bi);
      say("RESULT no-copy buffer: %s (memory %p, buffer pointer back %p)\n", buffer ? "created" : "FAILED", (void *)mem, bi.memory.ptr);
      if (pso && buffer) {
        obj_handle_t cb = p_MTLCommandQueue_commandBuffer(queue);
        obj_handle_t enc = p_MTLCommandBuffer_computeCommandEncoder(cb, false);
        wmtcmd_compute_setpso c1{}; c1.type = WMTComputeCommandSetPSO; c1.pso = pso; c1.threadgroup_size = {256, 1, 1};
        wmtcmd_compute_setbuffer c2{}; c2.type = WMTComputeCommandSetBuffer; c2.buffer = buffer; c2.offset = 0; c2.index = 0;
        wmtcmd_compute_dispatch c3{}; c3.type = WMTComputeCommandDispatchThreads; c3.size = {n, 1, 1};
        c1.next.ptr = &c2; c2.next.ptr = &c3; c3.next.ptr = nullptr;
        p_MTLComputeCommandEncoder_encodeCommands(enc, (const wmtcmd_base *)&c1);
        p_MTLCommandEncoder_endEncoding(enc);
        p_MTLCommandBuffer_commit(cb); p_MTLCommandBuffer_waitUntilCompleted(cb);
        bool ok = true; for (size_t i = 0; i < n; i++) if (mem[i] != (float)i + 1.0f) { ok = false; break; }
        say("RESULT zero-copy compute: command buffer status %d, memory changed in place: %s\n", (int)p_MTLCommandBuffer_status(cb), ok ? "YES" : "NO");
      }
    }
  }

  // ---- 1b. ray tracing through the Metal layer (calls 161-164): a bottom level structure of a quad, a top level structure with one moved instance, and rays traced against both
  {
    struct SizesCall { obj_handle_t device; uint64_t info; uint64_t out; };
    struct NewAccelCall { obj_handle_t device; uint64_t size; uint64_t resource_id; obj_handle_t ret; };
    struct EncCall { obj_handle_t handle; obj_handle_t ret; };
    struct BuildCall { obj_handle_t encoder; obj_handle_t structure; uint64_t info; obj_handle_t scratch; uint64_t scratch_offset; };
    auto shared_buffer = [&](size_t bytes, void **memory) -> obj_handle_t {
      bytes = (bytes + 65535) & ~(size_t)65535;
      void *m = VirtualAlloc(nullptr, bytes, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE); memset(m, 0, bytes);
      WMTBufferInfo bi{}; bi.length = bytes; bi.options = WMTResourceStorageModeShared; bi.memory.ptr = m;
      *memory = m; return p_MTLDevice_newBuffer(device, &bi);
    };
    auto build = [&](const WMTAccelInfo &info, const char *what, obj_handle_t *resource_out) -> obj_handle_t {
      WMTAccelSizes sizes{}; SizesCall sc{device, (uint64_t)(uintptr_t)&info, (uint64_t)(uintptr_t)&sizes};
      LONG r1 = (*dispatcher)(handle, 161, &sc);
      NewAccelCall nc{device, sizes.structure_size, 0, 0}; LONG r2 = (*dispatcher)(handle, 162, &nc);
      say("RESULT ray tracing %s: sizes call 0x%lx (structure %llu bytes, build scratch %llu), new structure call 0x%lx -> %s\n", what, (unsigned long)r1,
          (unsigned long long)sizes.structure_size, (unsigned long long)sizes.build_scratch_size, (unsigned long)r2, nc.ret ? "created" : "FAILED");
      if (!nc.ret) return 0;
      WMTBufferInfo sbi{}; sbi.length = sizes.build_scratch_size ? sizes.build_scratch_size : 16; sbi.options = WMTResourceStorageModePrivate;
      obj_handle_t scratch = p_MTLDevice_newBuffer(device, &sbi);
      obj_handle_t cb = p_MTLCommandQueue_commandBuffer(queue);
      EncCall ec{cb, 0}; (*dispatcher)(handle, 163, &ec);
      BuildCall bc{ec.ret, nc.ret, (uint64_t)(uintptr_t)&info, scratch, 0}; LONG r3 = (*dispatcher)(handle, 164, &bc);
      p_MTLCommandEncoder_endEncoding(ec.ret); p_MTLCommandBuffer_commit(cb); p_MTLCommandBuffer_waitUntilCompleted(cb);
      say("RESULT ray tracing %s build: call 0x%lx, command buffer status %d (4 = completed)\n", what, (unsigned long)r3, (int)p_MTLCommandBuffer_status(cb));
      if (resource_out) *resource_out = nc.resource_id;
      return nc.ret;
    };
    void *vmem, *imem, *omem, *dmem;
    obj_handle_t vbuf = shared_buffer(65536, &vmem), ibuf = shared_buffer(65536, &imem), obuf = shared_buffer(65536, &omem), dbuf = shared_buffer(65536, &dmem);
    float *v = (float *)vmem; const float quad[] = {-1, -1, 5, 1, -1, 5, 1, 1, 5, -1, 1, 5}; memcpy(v, quad, sizeof quad);
    uint32_t *ix = (uint32_t *)imem; const uint32_t tri[] = {0, 1, 2, 0, 2, 3}; memcpy(ix, tri, sizeof tri);
    WMTAccelTriangles geometry{}; geometry.vertex_buffer = vbuf; geometry.vertex_stride = 12; geometry.index_buffer = ibuf; geometry.index_type = 1; geometry.triangle_count = 2; geometry.flags = 1;
    WMTAccelInfo blas{}; blas.kind = WMT_ACCEL_KIND_PRIMITIVE; blas.count = 1; blas.geometries = (uint64_t)(uintptr_t)&geometry;
    obj_handle_t accel = build(blas, "bottom level (2 triangles)", nullptr);
    // one instance of it, moved 10 to the right: the 64-byte MTLAccelerationStructureInstanceDescriptor (12 floats of transform, options, mask, table offset, structure index)
    uint8_t *inst = (uint8_t *)dmem; float tr[12] = {1, 0, 0, 0, 1, 0, 0, 0, 1, 10, 0, 0}; memcpy(inst, tr, sizeof tr);
    uint32_t tail[4] = {0, 0xff, 0, 0}; memcpy(inst + 48, tail, sizeof tail);
    obj_handle_t blas_list[1] = {accel};
    WMTAccelInfo tlas{}; tlas.kind = WMT_ACCEL_KIND_INSTANCE; tlas.count = 1; tlas.instance_buffer = dbuf; tlas.instanced_structures = (uint64_t)(uintptr_t)blas_list; tlas.instanced_count = 1;
    tlas.use_resources = (uint64_t)(uintptr_t)blas_list; tlas.use_count = 1;
    obj_handle_t top = accel ? build(tlas, "top level (1 instance)", nullptr) : 0;

    obj_handle_t err = 0;
    obj_handle_t lib = compile(
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
        "  out[i] = res.type == intersection_type::triangle ? res.distance : -1.0f; }\n", 0x0302, &err);
    say("RESULT ray tracing kernels: %s %s\n", lib ? "compiled" : "FAILED", error_text(err).substr(0, 400).c_str());
    if (lib) {
      for (int pass = 0; pass < 2; pass++) {
        const char *name = pass ? "trace_inst" : "trace_prim"; obj_handle_t structure = pass ? top : accel;
        if (!structure) continue;
        WMTComputePipelineInfo pi{}; pi.compute_function = p_MTLLibrary_newFunction(lib, name); obj_handle_t perr = 0;
        obj_handle_t pso = p_MTLDevice_newComputePipelineState(device, &pi, &perr);
        if (!pso) { say("RESULT ray tracing %s: pipeline FAILED %s\n", name, error_text(perr).substr(0, 300).c_str()); continue; }
        float *out = (float *)omem; for (int k = 0; k < 256; k++) out[k] = -99.0f;
        obj_handle_t cb = p_MTLCommandQueue_commandBuffer(queue);
        obj_handle_t enc = p_MTLCommandBuffer_computeCommandEncoder(cb, false);
        wmtcmd_compute_setpso c1{}; c1.type = WMTComputeCommandSetPSO; c1.pso = pso; c1.threadgroup_size = {64, 1, 1};
        wmtcmd_compute_setaccel c2{}; c2.type = WMTComputeCommandSetAccelerationStructure; c2.accel = structure; c2.index = 0;
        wmtcmd_compute_useresource c3{}; c3.type = WMTComputeCommandUseResource; c3.resource = structure; c3.usage = WMTResourceUsageRead;
        wmtcmd_compute_useresource c3b{}; c3b.type = WMTComputeCommandUseResource; c3b.resource = accel; c3b.usage = WMTResourceUsageRead;
        wmtcmd_compute_setbuffer c4{}; c4.type = WMTComputeCommandSetBuffer; c4.buffer = obuf; c4.offset = 0; c4.index = 1;
        wmtcmd_compute_dispatch c5{}; c5.type = WMTComputeCommandDispatchThreads; c5.size = {256, 1, 1};
        c1.next.ptr = &c2; c2.next.ptr = &c3; c3.next.ptr = &c3b; c3b.next.ptr = &c4; c4.next.ptr = &c5;
        p_MTLComputeCommandEncoder_encodeCommands(enc, (const wmtcmd_base *)&c1); p_MTLCommandEncoder_endEncoding(enc);
        p_MTLCommandBuffer_commit(cb); p_MTLCommandBuffer_waitUntilCompleted(cb);
        int hits = 0, misses = 0, wrong = 0; for (int k = 0; k < 256; k++) { if (out[k] > 4.99f && out[k] < 5.01f) hits++; else if (out[k] == -1.0f) misses++; else wrong++; }
        say("RESULT ray tracing %s: status %d, %d rays hit the quad at distance 5 (expected 64), %d missed (expected 192), %d unexpected\n", name, (int)p_MTLCommandBuffer_status(cb), hits, misses, wrong);
      }
    }

    // ---- 1c. a custom intersection function (what Cycles uses for alpha tests and shadows): linked into a pipeline, put in an intersection function table, called by the hardware tracing
    if (accel) {
      struct PsoExCall { obj_handle_t device; uint64_t info; obj_handle_t ret_error; obj_handle_t ret; };
      struct NewIftCall { obj_handle_t pipeline; uint64_t function_count; uint64_t resource_id; obj_handle_t ret; };
      struct HandleCall { obj_handle_t handle; uint64_t arg; obj_handle_t ret; };
      struct SetFnCall { obj_handle_t table; obj_handle_t function_handle; uint64_t index; };
      WMTAccelTriangles geometry2 = geometry; geometry2.flags = 0;     // not opaque: the intersection function decides
      WMTAccelInfo blas2info{}; blas2info.kind = WMT_ACCEL_KIND_PRIMITIVE; blas2info.count = 1; blas2info.geometries = (uint64_t)(uintptr_t)&geometry2;
      obj_handle_t blas2 = build(blas2info, "bottom level, not opaque", nullptr);
      obj_handle_t lerr = 0;
      obj_handle_t ilib = compile(
          "#include <metal_stdlib>\n#include <metal_raytracing>\nusing namespace metal; using namespace raytracing;\n"
          "[[intersection(triangle, triangle_data)]] bool accept_right(float3 origin [[origin]]) { return origin.x > 0.0f; }\n"
          "kernel void trace_ift(primitive_acceleration_structure as [[buffer(0)]], intersection_function_table<triangle_data> ift [[buffer(1)]], device float *out [[buffer(2)]], uint i [[thread_position_in_grid]]) {\n"
          "  float x = -2.0f + 4.0f * (float(i % 16) + 0.5f) / 16.0f, y = -2.0f + 4.0f * (float(i / 16) + 0.5f) / 16.0f;\n"
          "  ray r; r.origin = float3(x, y, 0); r.direction = float3(0, 0, 1); r.min_distance = 0.001f; r.max_distance = 100.0f;\n"
          "  intersector<triangle_data> isect; intersection_result<triangle_data> res = isect.intersect(r, as, ift);\n"
          "  out[i] = res.type == intersection_type::triangle ? res.distance : -1.0f; }\n", 0x0302, &lerr);
      say("RESULT intersection function kernels: %s %s\n", ilib ? "compiled" : "FAILED", error_text(lerr).substr(0, 400).c_str());
      if (ilib && blas2) {
        obj_handle_t kernel_fn = p_MTLLibrary_newFunction(ilib, "trace_ift"), accept_fn = p_MTLLibrary_newFunction(ilib, "accept_right");
        obj_handle_t linked[1] = {accept_fn};
        WMTComputePipelineInfoEx pe{}; pe.compute_function = kernel_fn; pe.linked_functions = (uint64_t)(uintptr_t)linked; pe.linked_count = 1; pe.max_call_stack_depth = 2;
        PsoExCall pc{device, (uint64_t)(uintptr_t)&pe, 0, 0}; LONG r1 = (*dispatcher)(handle, 165, &pc);
        say("RESULT pipeline with a linked function: call 0x%lx -> %s %s\n", (unsigned long)r1, pc.ret ? "OK" : "FAILED", error_text(pc.ret_error).substr(0, 400).c_str());
        if (pc.ret) {
          NewIftCall nt{pc.ret, 1, 0, 0}; LONG r2 = (*dispatcher)(handle, 166, &nt);
          HandleCall hc{pc.ret, accept_fn, 0}; LONG r3 = (*dispatcher)(handle, 167, &hc);
          SetFnCall sf{nt.ret, hc.ret, 0}; LONG r4 = (*dispatcher)(handle, 168, &sf);
          say("RESULT intersection function table: create 0x%lx (%s, resource id %s), function handle 0x%lx (%s), set function 0x%lx\n", (unsigned long)r2, nt.ret ? "created" : "FAILED",
              nt.resource_id ? "set" : "zero", (unsigned long)r3, hc.ret ? "ok" : "FAILED", (unsigned long)r4);
          float *out = (float *)omem; for (int k = 0; k < 256; k++) out[k] = -99.0f;
          obj_handle_t cb = p_MTLCommandQueue_commandBuffer(queue);
          obj_handle_t enc = p_MTLCommandBuffer_computeCommandEncoder(cb, false);
          wmtcmd_compute_setpso c1{}; c1.type = WMTComputeCommandSetPSO; c1.pso = pc.ret; c1.threadgroup_size = {64, 1, 1};
          wmtcmd_compute_setaccel c2{}; c2.type = WMTComputeCommandSetAccelerationStructure; c2.accel = blas2; c2.index = 0;
          wmtcmd_compute_setift c3{}; c3.type = WMTComputeCommandSetIntersectionFunctionTable; c3.table = nt.ret; c3.index = 1;
          wmtcmd_compute_useresource c4{}; c4.type = WMTComputeCommandUseResource; c4.resource = blas2; c4.usage = WMTResourceUsageRead;
          wmtcmd_compute_useresource c5{}; c5.type = WMTComputeCommandUseResource; c5.resource = nt.ret; c5.usage = WMTResourceUsageRead;
          wmtcmd_compute_setbuffer c6{}; c6.type = WMTComputeCommandSetBuffer; c6.buffer = obuf; c6.offset = 0; c6.index = 2;
          wmtcmd_compute_dispatch c7{}; c7.type = WMTComputeCommandDispatchThreads; c7.size = {256, 1, 1};
          c1.next.ptr = &c2; c2.next.ptr = &c3; c3.next.ptr = &c4; c4.next.ptr = &c5; c5.next.ptr = &c6; c6.next.ptr = &c7;
          p_MTLComputeCommandEncoder_encodeCommands(enc, (const wmtcmd_base *)&c1); p_MTLCommandEncoder_endEncoding(enc);
          p_MTLCommandBuffer_commit(cb); p_MTLCommandBuffer_waitUntilCompleted(cb);
          int hits = 0, misses = 0, wrong = 0; for (int k = 0; k < 256; k++) { if (out[k] > 4.99f && out[k] < 5.01f) hits++; else if (out[k] == -1.0f) misses++; else wrong++; }
          say("RESULT custom intersection function: status %d, %d rays accepted (expected 32: only rays starting right of the middle), %d missed (expected 224), %d unexpected\n", (int)p_MTLCommandBuffer_status(cb), hits, misses, wrong);
        }
      }
    }
  }

  // ---- 2. Cycles' own kernel source (embedded in this program), compiled the way Cycles does at run time
  HRSRC r = FindResourceA(nullptr, MAKEINTRESOURCEA(1), RT_RCDATA);
  if (!r) { say("RESULT cycles kernel source: not embedded\n"); return 0; }
  const char *body = (const char *)LockResource(LoadResource(nullptr, r)); size_t blen = SizeofResource(nullptr, r);
  for (int rt = 1; rt >= 0; rt--) {   // the ray-tracing library first (it is only a compile), then the pipelines of the plain one
    std::string src = std::string("#define __KERNEL_METAL_APPLE__\n#define __METAL_GLOBAL_BUILTINS__\n#define __KERNEL_METAL_MACOS__ 27\n#define __KERNEL_METAL_TARGET_CPU_ARM64__\n") + (rt ? "#define __KERNEL_METALRT__\n" : "") + std::string(body, blen);
    obj_handle_t err = 0; double t0 = now();
    obj_handle_t lib = compile(src, 0x0302, &err);
    say("RESULT cycles kernel library (%s, %.1f MB): %s in %.1f s %s\n", rt ? "with MetalRT" : "no MetalRT", src.size() / 1048576.0, lib ? "OK" : "FAILED", now() - t0, error_text(err).substr(0, 600).c_str());
    if (lib && !rt) {
      // The big kernels take a long time to turn into GPU code the first time (Cycles builds them in the background and keeps them in a cache). Build each on a worker thread and say how long it has taken every 10 s.
      const char *names[] = {"cycles_metal_integrator_init_from_camera", "cycles_metal_integrator_queued_paths_array", "cycles_metal_integrator_intersect_shadow",
                             "cycles_metal_integrator_shade_background", "cycles_metal_integrator_shade_surface"};
      for (const char *name : names) {
        struct Job { obj_handle_t device, lib; const char *name; decltype(&MTLLibrary_newFunction) nf; decltype(&MTLDevice_newComputePipelineState) np; volatile LONG done; obj_handle_t fn, pso, err; } job{};
        job.device = device; job.lib = lib; job.name = name; job.nf = p_MTLLibrary_newFunction; job.np = p_MTLDevice_newComputePipelineState;
        double t1 = now();
        HANDLE th = CreateThread(nullptr, 0, [](LPVOID q) -> DWORD {
          Job *j = (Job *)q; j->fn = j->nf(j->lib, j->name);
          WMTComputePipelineInfo pi{}; pi.compute_function = j->fn;
          j->pso = j->fn ? j->np(j->device, &pi, &j->err) : 0; InterlockedExchange(&j->done, 1); return 0; }, &job, 0, nullptr);
        double next = 10;
        while (!job.done && now() - t1 < 1200) { Sleep(250); if (now() - t1 >= next) { say("RESULT ... still building %s: %.0f s\n", name, now() - t1); next += 10; } }
        if (!job.done) { say("RESULT pipeline %s: gave up after 20 minutes\n", name); CloseHandle(th); break; }
        WaitForSingleObject(th, INFINITE); CloseHandle(th);
        say("RESULT pipeline %s: %s in %.1f s %s\n", name, job.pso ? "OK" : (job.fn ? "FAILED" : "no such function"), now() - t1, error_text(job.err).substr(0, 300).c_str());
      }
    }
  }
  say("RESULT done - you can close this window\n");
  return 0;
}

static DWORD WINAPI run_and_finish(LPVOID p) { run_tests(p); InterlockedExchange(&g_finished, 1); return 0; }

int main() {
  g_start = now();
  WNDCLASSA wc{}; wc.lpfnWndProc = window_proc; wc.hInstance = GetModuleHandleA(nullptr); wc.lpszClassName = "MetalTest"; wc.hCursor = LoadCursorA(nullptr, IDC_ARROW); wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
  RegisterClassA(&wc);
  g_window = CreateWindowExA(0, "MetalTest", "Metal test", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 40, 40, 900, 560, nullptr, nullptr, wc.hInstance, nullptr);
  CreateThread(nullptr, 0, run_and_finish, nullptr, 0, nullptr);
  MSG msg; while (GetMessageA(&msg, nullptr, 0, 0) > 0) { TranslateMessage(&msg); DispatchMessageA(&msg); }
  return 0;
}
