// Compiles repro.shaderbundle.json into build/shaderbundles/repro.shaderbundle
// (flutter_gpu_shaders 0.4.x hooks API; legacyOnly = load via ShaderLibrary.fromAsset).
// ignore_for_file: depend_on_referenced_packages
import 'package:flutter_gpu_shaders/build.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    await buildShaderBundleJson(
      buildInput: input,
      buildOutput: output,
      manifestFileName: 'repro.shaderbundle.json',
      includeDirectories: [input.packageRoot.resolve('shaders/')],
      assetMode: ShaderBundleAssetMode.legacyOnly,
    );
  });
}
