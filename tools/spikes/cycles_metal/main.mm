// Spike: can Cycles' own Metal kernel be compiled from source with newLibraryWithSource (as Cycles does at run time), and can a compute pipeline be built from it?
// Also: does a Metal buffer wrapped around ordinary malloc'd memory (no copy) see and change that memory?
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <regex>
#include <string>
#include <fstream>
#include <sstream>
#include <chrono>
#include <set>

static std::string readFile(const std::string &p) { std::ifstream f(p); std::stringstream s; s << f.rdbuf(); return s.str(); }
// like Cycles' path_source_replace_includes: quoted includes are replaced by the file's text, recursively
static std::set<std::string> done;
#include <filesystem>
// exactly Cycles' path_source_replace_includes: a quoted include is looked up under the root, then next to the including file; only a file that says "#pragma once" is left out the second time
static std::string expandFile(const std::string &full, const std::string &root, int depth = 0) {
  static std::regex inc("^[ \\t]*#[ \\t]*include[ \\t]+\"([^\"]+)\".*$");
  std::string src = readFile(full);
  size_t p = src.find("#pragma once");
  if (p != std::string::npos) { if (!done.insert(full).second) return ""; src.replace(p, 12, "//pr"); }
  std::stringstream in(src); std::string line, out; std::smatch m;
  while (std::getline(in, line)) {
    if (std::regex_match(line, m, inc) && depth < 40) {
      std::string f = root + "/" + m[1].str();
      if (!std::filesystem::exists(f)) f = std::filesystem::path(full).parent_path().string() + "/" + m[1].str();
      if (std::filesystem::exists(f)) { out += expandFile(std::filesystem::path(f).lexically_normal().string(), root, depth + 1); out += "\n"; } else { out += line; out += "\n"; }
    }
    else { out += line; out += "\n"; }
  }
  return out;
}
static double now() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }

int main(int argc, char **argv) { setvbuf(stdout, NULL, _IONBF, 0);
  @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    printf("device: %s, apple9=%d raytracing=%d unified=%d maxBuffer=%llu MB\n", dev.name.UTF8String, (int)[dev supportsFamily:MTLGPUFamilyApple9], (int)dev.supportsRaytracing, (int)dev.hasUnifiedMemory, dev.maxBufferLength >> 20);

    // ---- 1. zero-copy: a buffer around ordinary memory, a kernel that adds 1 to every element
    {
      size_t n = 1 << 20, bytes = n * 4; void *mem = nullptr; posix_memalign(&mem, 16384, bytes);
      float *p = (float *)mem; for (size_t i = 0; i < n; i++) p[i] = (float)i;
      id<MTLBuffer> buf = [dev newBufferWithBytesNoCopy:mem length:bytes options:MTLResourceStorageModeShared deallocator:nil];
      NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\nkernel void add1(device float *a [[buffer(0)]], uint i [[thread_position_in_grid]]) { a[i] += 1.0f; }\n";
      NSError *err = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&err];
      id<MTLComputePipelineState> pso = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"add1"] error:&err];
      id<MTLCommandQueue> q = [dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
      [enc setComputePipelineState:pso]; [enc setBuffer:buf offset:0 atIndex:0];
      [enc dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)]; [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
      bool ok = true; for (size_t i = 0; i < n; i++) if (p[i] != (float)i + 1.0f) { ok = false; break; }
      printf("zero-copy: buffer around malloc'd memory (%zu MB): kernel result visible in the same memory without a copy: %s\n", bytes >> 20, ok ? "YES" : "NO");
    }

    // ---- 2. Cycles' kernel
    std::string root = argc > 1 ? argv[1] : ".";
    for (int variant = 0; variant < 2; variant++) {
      bool rt = variant == 1;
      std::string defs = "#define __KERNEL_METAL_APPLE__\n#define __METAL_GLOBAL_BUILTINS__\n#define __KERNEL_METAL_MACOS__ 26\n#define __KERNEL_METAL_TARGET_CPU_ARM64__\n";
      if (rt) defs += "#define __KERNEL_METALRT__\n";
      done.clear(); std::string source = defs + expandFile(root + "/kernel/device/metal/kernel.metal", root);
      printf("\n[%s] source: %.1f MB after includes\n", rt ? "with MetalRT" : "no MetalRT", source.size() / 1048576.0);
      MTLCompileOptions *opt = [MTLCompileOptions new]; opt.fastMathEnabled = YES; opt.languageVersion = MTLLanguageVersion3_2;
      double t0 = now(); NSError *err = nil;
      id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:source.c_str()] options:opt error:&err];
      printf("[%s] newLibraryWithSource: %.1f s, %s\n", rt ? "with MetalRT" : "no MetalRT", now() - t0, lib ? "OK" : "FAILED");
      if (!lib) { { NSMutableString *e = [NSMutableString string]; for (NSString *l in [[err localizedDescription] componentsSeparatedByString:@"\n"]) if ([l containsString:@"error"]) { [e appendFormat:@"%@\n", l]; } printf("%s\n", [[e substringToIndex:MIN(2000, e.length)] UTF8String]); } continue; }
      printf("[%s] %lu kernel functions, e.g. %s\n", rt ? "with MetalRT" : "no MetalRT", (unsigned long)lib.functionNames.count, [[[lib.functionNames subarrayWithRange:NSMakeRange(0, MIN(4, lib.functionNames.count))] componentsJoinedByString:@", "] UTF8String]);
      if (!rt) {
        for (NSString *name in lib.functionNames) {
          if (![name containsString:@"init_from_camera"] && ![name containsString:@"queued_paths_array"]) continue;
          MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new];
          NSError *e2 = nil; double t1 = now();
          id<MTLFunction> fn = [lib newFunctionWithName:name constantValues:cv error:&e2];
          if (!fn) { printf("function %s: %s\n", name.UTF8String, e2.localizedDescription.UTF8String); continue; }
          id<MTLComputePipelineState> pso = [dev newComputePipelineStateWithFunction:fn error:&e2];
          printf("pipeline %s: %s in %.1f s (maxThreads %lu, regs/spill n/a)\n", name.UTF8String, pso ? "OK" : e2.localizedDescription.UTF8String, now() - t1, pso ? (unsigned long)pso.maxTotalThreadsPerThreadgroup : 0UL);
        }
      }
    }
  }
  return 0;
}
