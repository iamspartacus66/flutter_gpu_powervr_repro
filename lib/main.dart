// Minimal reproduction: Flutter GPU, TWO render passes per frame sharing one
// devicePrivate MSAA color + depth/stencil attachment pair (pass 1 clears and
// stores; pass 2 LOADs both, draws, and multisample-resolves into the presented
// texture). On a Pixel 10 (Tensor G5, PowerVR DXT-48-1536, driver 25.3) with
// Impeller's Vulkan backend this SIGSEGVs inside vulkan.powervr.so
// (CmdBeginRenderPass2) within seconds. The same code is fine on the OpenGL ES
// backend, on macOS/iOS Metal, and on Adreno/Mali Vulkan devices we tried.
//
// Modes (toggle at the top):
//   single   — control: one pass, clear + resolve.
//   two      — pass 1 clear/store, pass 2 load/resolve (distinct pipelines).
//   depth+2  — as "two", preceded by a depth-only pre-pass into a sampled
//              r32Float texture (2048², like a shadow map) that both main
//              passes then sample — the real renderer's structure.
//   empty+2  — as depth+2 but pass 1 has NO draw commands (clear + store only).
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart' as vm32;

void main() => runApp(MaterialApp(theme: ThemeData.dark(), home: const ReproPage()));

class ReproPage extends StatefulWidget {
  const ReproPage({super.key});
  @override
  State<ReproPage> createState() => _ReproPageState();
}

class _ReproPageState extends State<ReproPage>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final Renderer _renderer = Renderer();
  Mode _mode = Mode.emptyTwo;
  bool _big = true; // render a 1974² target (the real app's high tier) vs screen size
  bool _msaa = true; // 4× MSAA + resolve vs. draw straight into the presented texture
  int _frame = 0;
  final Stopwatch _clock = Stopwatch()..start();
  String? _error;

  @override
  void initState() {
    super.initState();
    _renderer.init().then((_) {
      _ticker = createTicker((_) => setState(() => _frame++))..start();
    }).catchError((Object e) => setState(() => _error = '$e'));
  }

  @override
  void dispose() {
    _ticker.dispose();
    _renderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SegmentedButton<Mode>(
                    segments: const [
                      ButtonSegment(value: Mode.single, label: Text('single')),
                      ButtonSegment(value: Mode.two, label: Text('two')),
                      ButtonSegment(value: Mode.depthTwo, label: Text('depth+2')),
                      ButtonSegment(value: Mode.emptyTwo, label: Text('empty+2')),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (s) => setState(() => _mode = s.first),
                  ),
                  const SizedBox(height: 6),
                  Row(children: [
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: true, label: Text('1974²')),
                        ButtonSegment(value: false, label: Text('screen')),
                      ],
                      selected: {_big},
                      onSelectionChanged: (s) => setState(() => _big = s.first),
                    ),
                    const SizedBox(width: 8),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: true, label: Text('MSAA')),
                        ButtonSegment(value: false, label: Text('no AA')),
                      ],
                      selected: {_msaa},
                      onSelectionChanged: (s) => setState(() => _msaa = s.first),
                    ),
                  ]),
                  const SizedBox(height: 4),
                  Row(children: [
                    Text(
                      'frame $_frame  ${_clock.elapsed.inSeconds}s',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ]),
                ],
              ),
            ),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: Colors.red)),
            Expanded(
              child: CustomPaint(
                painter: _Painter(_renderer, _mode, _big, _msaa, _frame),
                child: const SizedBox.expand(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum Mode { single, two, depthTwo, emptyTwo }

class _Painter extends CustomPainter {
  _Painter(this.renderer, this.mode, this.big, this.msaa, this.frame);
  final Renderer renderer;
  final Mode mode;
  final bool big;
  final bool msaa;
  final int frame;

  @override
  void paint(Canvas canvas, Size size) {
    if (!renderer.ready) return;
    final dpr = ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
    final w = big ? 1974 : (size.width * dpr).round();
    final h = big ? 1974 : (size.height * dpr).round();
    if (w <= 0 || h <= 0) return;
    final image = renderer.render(w, h, mode, msaa, frame);
    // Downscale into a square that fits the widget (the real app's SSAA).
    final side = math.min(size.width, size.height);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Rect.fromLTWH(0, 0, side, big ? side : size.height),
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_Painter old) => true;
}

/// Indexed meshes (position only, stride 12) like the real renderer's props
/// (a mesh torus ring) and rope (a tube that GROWS along its path each frame).
class Mesh {
  Mesh(this.vertices, this.indices);
  final Float32List vertices;
  final Int32List indices;
  int get indexCount => indices.length;

  /// Torus: `segs × sides` quads.
  static Mesh torus({double major = 0.45, double minor = 0.08, int segs = 96, int sides = 32}) {
    final v = <double>[];
    final idx = <int>[];
    for (var i = 0; i < segs; i++) {
      final a = 2 * math.pi * i / segs;
      for (var j = 0; j < sides; j++) {
        final b = 2 * math.pi * j / sides;
        final r = major + minor * math.cos(b);
        v.addAll([r * math.cos(a), r * math.sin(a), 0.5 + minor * math.sin(b) * 0.2]);
      }
    }
    for (var i = 0; i < segs; i++) {
      for (var j = 0; j < sides; j++) {
        final a = i * sides + j, b = i * sides + (j + 1) % sides;
        final c = ((i + 1) % segs) * sides + j, d = ((i + 1) % segs) * sides + (j + 1) % sides;
        idx.addAll([a, b, c, b, d, c]);
      }
    }
    return Mesh(Float32List.fromList(v), Int32List.fromList(idx));
  }

  /// Tube around a helix, `rings` cross-sections of `sides` vertices. The
  /// caller draws a growing PREFIX of the index list each frame.
  static Mesh helixTube({int rings = 600, int sides = 33, double radius = 0.05}) {
    final v = <double>[];
    final idx = <int>[];
    for (var i = 0; i < rings; i++) {
      final t = i / (rings - 1);
      final a = 6 * math.pi * t;
      final cx = 0.5 * math.cos(a), cy = 0.5 * math.sin(a), cz = 0.2 + 0.6 * t;
      for (var j = 0; j < sides; j++) {
        final b = 2 * math.pi * j / (sides - 1);
        v.addAll([cx + radius * math.cos(b), cy + radius * math.sin(b), cz + radius * math.sin(a) * 0.1]);
      }
    }
    for (var i = 0; i < rings - 1; i++) {
      for (var j = 0; j < sides - 1; j++) {
        final a = i * sides + j, b = a + 1, c = a + sides, d = c + 1;
        idx.addAll([a, b, c, b, d, c]);
      }
    }
    return Mesh(Float32List.fromList(v), Int32List.fromList(idx));
  }
}

class Renderer {
  static const _kColorFormat = gpu.PixelFormat.r8g8b8a8UNormInt;
  static const _kRing = 4;

  static const _kShadowSize = 2048;

  // Two main pipelines from the same shaders (the real renderer draws pass 1
  // and pass 2 with different pipelines) + a depth-only pre-pass pipeline.
  late gpu.RenderPipeline _pipelineA;
  late gpu.RenderPipeline _pipelineB;
  late gpu.RenderPipeline _depthPipeline;
  late gpu.UniformSlot _infoSlot;
  late gpu.UniformSlot _shadowSlot;
  late gpu.Texture _shadowTex;
  late gpu.Texture _shadowDepth;
  late gpu.Texture _farTex;
  // Ring: static DeviceBuffers (uploaded once). Tube: emplaced through a
  // HostBuffer every frame (the real renderer's per-frame rope mesh).
  final Mesh _ringMesh = Mesh.torus();
  final Mesh _tube = Mesh.helixTube();
  late gpu.DeviceBuffer _ringVerts;
  late gpu.DeviceBuffer _ringIndices;
  late gpu.HostBuffer _host;
  bool ready = false;

  gpu.Texture? _msaaColor;
  gpu.Texture? _depth;
  int _attW = 0, _attH = 0;
  bool _attMsaa = true;
  final List<gpu.Texture?> _ring = List.filled(_kRing, null);
  int _ringIndex = 0;
  ui.Image? _lastImage;

  Future<void> init() async {
    final library =
        await gpu.ShaderLibrary.fromAsset('build/shaderbundles/repro.shaderbundle');
    final vert = library!['SimpleVertex']!;
    final frag = library['SimpleFragment']!;
    final depthFrag = library['DepthFragment']!;
    final layout = gpu.VertexLayout(buffers: [
      gpu.VertexBuffer(strideInBytes: 12, attributes: [
        gpu.VertexAttribute(
            name: 'position',
            format: gpu.VertexFormat.float32x3,
            offsetInBytes: 0),
      ]),
    ]);
    _pipelineA =
        gpu.gpuContext.createRenderPipeline(vert, frag, vertexLayout: layout);
    _pipelineB =
        gpu.gpuContext.createRenderPipeline(vert, frag, vertexLayout: layout);
    _depthPipeline = gpu.gpuContext
        .createRenderPipeline(vert, depthFrag, vertexLayout: layout);
    _infoSlot = vert.getUniformSlot('Info');
    _shadowSlot = frag.getUniformSlot('shadowTex');
    // Pre-pass target: sampled r32Float (devicePrivate) + a transient depth.
    _shadowTex = gpu.gpuContext.createTexture(
        gpu.StorageMode.devicePrivate, _kShadowSize, _kShadowSize,
        format: gpu.PixelFormat.r32Float);
    _shadowDepth = gpu.gpuContext.createTexture(
        gpu.StorageMode.deviceTransient, _kShadowSize, _kShadowSize,
        format: gpu.gpuContext.defaultDepthStencilFormat);
    // 1x1 "far" map bound when the pre-pass is off (every sampler must be bound).
    _farTex = gpu.gpuContext.createTexture(gpu.StorageMode.hostVisible, 1, 1,
        format: gpu.PixelFormat.r32Float);
    _farTex.overwrite(Float32List.fromList([1.0]).buffer.asByteData());
    _ringVerts = gpu.gpuContext
        .createDeviceBufferWithCopy(_ringMesh.vertices.buffer.asByteData());
    _ringIndices = gpu.gpuContext
        .createDeviceBufferWithCopy(_ringMesh.indices.buffer.asByteData());
    // One block must hold EVERYTHING emplaced in a frame (the tube goes through
    // two passes) — flutter_gpu's overflow check only tests the padding.
    _host = gpu.gpuContext.createHostBuffer(
        blockLengthInBytes: 2 *
                (_tube.vertices.lengthInBytes + _tube.indices.lengthInBytes) +
            64 * 1024);
    debugPrint('repro: ring ${_ringMesh.indexCount ~/ 3} tris, tube ${_tube.indexCount ~/ 3} tris');
    debugPrint('flutter_gpu: offscreenMSAA=${gpu.gpuContext.doesSupportOffscreenMSAA}');
    ready = true;
  }

  void dispose() {
    _lastImage?.dispose();
    _lastImage = null;
  }

  ui.Image render(int width, int height, Mode mode, bool wantMsaa, int frame) {
    _lastImage?.dispose();
    _lastImage = null;
    _host.reset();
    final twoPass = mode != Mode.single;
    final prePass = mode == Mode.depthTwo || mode == Mode.emptyTwo;
    // empty+2: pass 1 is encoded (clear + store) with NO draw commands — the
    // shape the real renderer has when its prop draws are skipped.
    final emptyPass1 = mode == Mode.emptyTwo;
    final sampled = prePass ? _shadowTex : _farTex;

    final msaa = wantMsaa && gpu.gpuContext.doesSupportOffscreenMSAA;
    final samples = msaa ? 4 : 1;

    // Attachments: devicePrivate so pass 2 may LOAD them. Render-target only.
    if (_depth == null || _attW != width || _attH != height || _attMsaa != msaa) {
      _msaaColor = msaa
          ? gpu.gpuContext.createTexture(
              gpu.StorageMode.devicePrivate, width, height,
              format: _kColorFormat,
              sampleCount: samples,
              enableShaderReadUsage: false)
          : null;
      _depth = gpu.gpuContext.createTexture(
          gpu.StorageMode.devicePrivate, width, height,
          format: gpu.gpuContext.defaultDepthStencilFormat,
          sampleCount: samples,
          enableShaderReadUsage: false);
      for (var i = 0; i < _kRing; i++) {
        _ring[i] = null;
      }
      _attW = width;
      _attH = height;
      _attMsaa = msaa;
    }
    _ringIndex = (_ringIndex + 1) % _kRing;
    final resolveTex = _ring[_ringIndex] ??= gpu.gpuContext.createTexture(
        gpu.StorageMode.devicePrivate, width, height,
        format: _kColorFormat);
    final colorTarget = msaa ? _msaaColor! : resolveTex;
    final clear = vm32.Vector4(0.05, 0.05, 0.1, 1.0);

    // ---- Pass 0 (depth+2 only): depth-only pre-pass into the sampled
    // r32Float texture, both triangles. Own command buffer.
    if (prePass) {
      final cmd0 = gpu.gpuContext.createCommandBuffer();
      final pass0 = cmd0.createRenderPass(gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(
          texture: _shadowTex,
          storeAction: gpu.StoreAction.store,
          clearValue: vm32.Vector4(1.0, 1.0, 1.0, 1.0),
        ),
        depthStencilAttachment: gpu.DepthStencilAttachment(
          texture: _shadowDepth,
          depthClearValue: 1.0,
        ),
      ));
      _drawRing(pass0, _depthPipeline, null, frame);
      _drawTube(pass0, _depthPipeline, null, frame);
      cmd0.submit();
    }

    // ---- Pass 1 (two-pass modes): clear + store color and depth/stencil,
    // draw a red triangle. Own command buffer.
    if (twoPass) {
      final cmd1 = gpu.gpuContext.createCommandBuffer();
      final pass1 = cmd1.createRenderPass(gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(
          texture: colorTarget,
          loadAction: gpu.LoadAction.clear,
          storeAction: gpu.StoreAction.store,
          clearValue: clear,
        ),
        depthStencilAttachment: gpu.DepthStencilAttachment(
          texture: _depth!,
          depthLoadAction: gpu.LoadAction.clear,
          depthStoreAction: gpu.StoreAction.store,
          depthClearValue: 1.0,
          stencilLoadAction: gpu.LoadAction.clear,
          stencilStoreAction: gpu.StoreAction.store,
        ),
      ));
      if (!emptyPass1) _drawRing(pass1, _pipelineA, sampled, frame);
      cmd1.submit();
    }

    // ---- Pass 2: LOAD (two-pass) or clear (single-pass) color + depth/stencil,
    // draw a green triangle, multisample-resolve into the presented texture.
    final cmd2 = gpu.gpuContext.createCommandBuffer();
    final load = twoPass ? gpu.LoadAction.load : gpu.LoadAction.clear;
    final pass2 = cmd2.createRenderPass(gpu.RenderTarget.singleColor(
      gpu.ColorAttachment(
        texture: colorTarget,
        resolveTexture: msaa ? resolveTex : null,
        loadAction: load,
        storeAction:
            msaa ? gpu.StoreAction.multisampleResolve : gpu.StoreAction.store,
        clearValue: clear,
      ),
      depthStencilAttachment: gpu.DepthStencilAttachment(
        texture: _depth!,
        depthLoadAction: load,
        depthStoreAction: gpu.StoreAction.dontCare,
        depthClearValue: 1.0,
        stencilLoadAction: load,
        stencilStoreAction: gpu.StoreAction.dontCare,
      ),
    ));
    _drawTube(pass2, _pipelineB, sampled, frame);
    cmd2.submit();

    return _lastImage = resolveTex.asImage();
  }

  /// The ring: static buffers, gold.
  void _drawRing(gpu.RenderPass pass, gpu.RenderPipeline pipeline,
      gpu.Texture? sampled, int frame) {
    _bind(pass, pipeline, sampled, frame * 0.01, const [0.9, 0.7, 0.3, 1.0]);
    pass.bindVertexBuffer(gpu.BufferView(_ringVerts,
        offsetInBytes: 0, lengthInBytes: _ringVerts.sizeInBytes));
    pass.bindIndexBuffer(
        gpu.BufferView(_ringIndices,
            offsetInBytes: 0, lengthInBytes: _ringIndices.sizeInBytes),
        gpu.IndexType.int32);
    pass.drawIndexed(_ringMesh.indexCount);
  }

  /// The tube: a growing prefix (the tie), emplaced through the HostBuffer
  /// every frame, green.
  void _drawTube(gpu.RenderPass pass, gpu.RenderPipeline pipeline,
      gpu.Texture? sampled, int frame) {
    final grow = ((frame % 900) / 600.0).clamp(0.05, 1.0); // grow, then hold
    final tris = (_tube.indexCount ~/ 3 * grow).toInt();
    final count = tris * 3;
    _bind(pass, pipeline, sampled, frame * 0.01, const [0.3, 0.9, 0.4, 1.0]);
    pass.bindVertexBuffer(_host.emplace(_tube.vertices.buffer.asByteData()));
    pass.bindIndexBuffer(
        _host.emplace(_tube.indices.buffer.asByteData(0, count * 4)),
        gpu.IndexType.int32);
    pass.drawIndexed(count);
  }

  void _bind(gpu.RenderPass pass, gpu.RenderPipeline pipeline,
      gpu.Texture? sampled, double angle, List<double> rgba) {
    pass.bindPipeline(pipeline);
    pass.setDepthWriteEnable(true);
    pass.setDepthCompareOperation(gpu.CompareFunction.less);
    if (sampled != null) {
      pass.bindTexture(_shadowSlot, sampled,
          sampler: gpu.SamplerOptions(
            minFilter: gpu.MinMagFilter.nearest,
            magFilter: gpu.MinMagFilter.nearest,
            widthAddressMode: gpu.SamplerAddressMode.clampToEdge,
            heightAddressMode: gpu.SamplerAddressMode.clampToEdge,
          ));
    }
    final c = math.cos(angle), s = math.sin(angle);
    // Column-major mat4: orbit about the vertical axis (the lab's drag orbit)
    // then a vec4 color (std140).
    final info = Float32List.fromList([
      c, 0, s, 0, //
      0, 1, 0, 0, //
      -s, 0, c, 0, //
      0, 0, 0, 1, //
      rgba[0], rgba[1], rgba[2], rgba[3],
    ]);
    pass.bindUniform(_infoSlot, _host.emplace(info.buffer.asByteData()));
  }
}
