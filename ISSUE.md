<!-- Draft for github.com/flutter/flutter/issues/new/choose → Bug report. Edit freely. -->

## Title

[Impeller][Vulkan][flutter_gpu] Pixel 10 (PowerVR DXT, driver 25.3): LoadAction.load of a color attachment stored by a previous render pass yields nothing; with MSAA the app SIGSEGVs in vulkan.powervr.so (CmdBeginRenderPass2)

## Steps to reproduce

Minimal app: https://github.com/<your-account>/flutter_gpu_powervr_repro (one Dart file + two tiny shaders).

1. `flutter run -d <pixel 10> --profile` (Impeller selects Vulkan on this device: driver 25.3 passes the ≥ 25.1 gate in `driver_info_vk.cc`).
2. Leave mode `two` (pass 1: clear + store, draws a gold ring; pass 2: `LoadAction.load` color + depth/stencil, draws a green tube) and switch AA to `no AA`.
3. The gold ring disappears. Switch back to `MSAA` and it returns. `single` mode (no load) is always correct.

Each pass is its own `CommandBuffer`; attachments are `StorageMode.devicePrivate`, `enableShaderReadUsage: false` for the depth/stencil and MSAA color; the presented texture is a `devicePrivate` r8g8b8a8 texture returned via `asImage()`.

## Expected results

Pass 2 loads the color/depth that pass 1 stored, so both objects render (as on Metal, on the same phone with the OpenGL ES backend forced, and on Adreno/Mali Vulkan devices).

## Actual results

On the Pixel 10 Vulkan backend the loaded color comes back empty (no AA). In our full renderer (same two-pass structure with 4× MSAA + `multisampleResolve`, plus a depth pre-pass and textures) the process instead crashes inside the vendor driver within seconds to a minute, every time a scene with the second pass is shown; the MSAA form has not yet been reduced to the minimal app (the minimal app with MSAA renders for 2+ minutes).

Crash backtrace from the full app (profile build, Flutter 3.47.5; identical on 3.47.6 and on master 3.49.0-1.0.pre-368):

```
Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x796eedd7b2
Build fingerprint: 'google/frankel/frankel:17/CP3A.260905.009/16091614:user/release-keys'
#00 pc 0000000000087ae8  /vendor/lib64/hw/vulkan.powervr.so (CmdBeginRenderPass2+2824)
#01 pc 0000000000181114  /vendor/lib64/hw/vulkan.powervr.so (IMG_vkCmdBeginRenderPass+52)
#02 pc 000000000087e9b8  libflutter.so
#03 pc 00000000007c7cc8  libflutter.so
#04 pc 0000000000932a28  libflutter.so (InternalFlutterGpu_RenderPass_...)
```

(An earlier variant with depth-store + stencil-dontCare split faulted in the driver's `SetupZLSState` instead; making the stencil actions follow the depth actions moved the fault to `CmdBeginRenderPass2`.)

The fault address is identical across processes/runs, which suggests an out-of-bounds read of a fixed driver table rather than a use-after-free.

Not reproducible on: the same phone with `ImpellerBackend=opengles` (profile build — everything renders, no crash); macOS/iOS Metal; Adreno/Mali Vulkan devices.

## Device

- Google Pixel 10 (`frankel`), Android 17, build `CP3A.260905.009`
- GPU: PowerVR D-Series DXT-48-1536 MC1, Vulkan driver `25.3@6908880` (driverVersion 6908880, vendorID 0x1010, deviceID 0x71061212), Vulkan API 1.4
- `Knot3dCapabilities`/`GpuContext`: `doesSupportOffscreenMSAA=true`, `doesSupportManuallyMippedTextures=true`, `doesSupportFramebufferRenderMipmap=true`, `maxSamplerAnisotropy=16`

## Flutter

```
<paste `flutter doctor -v`>
```

Flutter 3.47.6 (stable, engine 692136cb65). Also reproduced on master 3.49.0-1.0.pre-368 (fa309e6026).

## Notes

- Related: #179812 (re-enabled Vulkan on the Pixel 10 behind a driver ≥ 25.1 gate), #161841 (PowerVR < CXT barred from Vulkan). This device passes the gate.
- The only PowerVR workaround currently applied (`workarounds_vk.cc`) is `input_attachment_self_dependency_broken`; the loaded attachment here is a plain color/depth attachment, not an input attachment.
- Happy to test engine builds / workarounds on the device.
