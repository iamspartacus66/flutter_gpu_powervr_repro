# flutter_gpu_powervr_repro

Minimal Flutter GPU app that shows a PowerVR Vulkan driver defect on the
Pixel 10 (Tensor G5, PowerVR D-Series DXT-48-1536 MC1, driver 25.3@6908880,
Android 17 `CP3A.260905.009`): **a render pass that `LoadAction.load`s a color
attachment stored by a previous render pass (separate command buffer) gets
nothing back** — the first pass's output is lost. With 4× MSAA the same
structure instead crashes (SIGSEGV in `vulkan.powervr.so`, `CmdBeginRenderPass2`)
in a larger app; this minimal app shows the silent-loss form deterministically.

Each frame the app draws a gold **ring** in pass 1 (clear + store) and a green
**tube** in pass 2 (load, draw, store/resolve) into the same attachments, and
presents the result through `Texture.asImage()`.

Controls (top):

| Row | Options | Meaning |
|---|---|---|
| mode | `single` / `two` / `depth+2` / `empty+2` | one pass (control) / two passes / depth pre-pass + two / two with an empty pass 1 |
| size | `1974²` / `screen` | offscreen target size |
| AA | `MSAA` / `no AA` | 4× MSAA + resolve vs. draw straight into the presented texture |

## Result on the Pixel 10 (Impeller Vulkan)

| mode | AA | result |
|---|---|---|
| `two` or `depth+2` | MSAA | renders correctly (ring + tube) for 2+ minutes |
| `two` or `depth+2` | **no AA** | **gold ring missing** — pass 2's load of pass 1's stored color yields nothing |
| `single` | either | correct (no load involved) |

The same APK with the OpenGL ES backend forced
(`io.flutter.embedding.android.ImpellerBackend=opengles`, profile build) renders
the ring in every mode. macOS/iOS (Metal) and the Adreno / Mali Vulkan devices we
tried are also correct.

## Run

```sh
flutter run -d <pixel-10> --profile
```

Flutter 3.47.6 stable (also reproduced on master 3.49.0-1.0.pre-368).
