# Proton-CachyOS —— CachyOS 官方二进制（SLR = Steam Linux Runtime 容器构建）
# 上游只发布 SLR 二进制；「native」仅 AUR 源码包，NixOS 上不适用。
# 用法一：programs.steam.extraCompatPackages（Steam 游戏）
# 用法二：PROTONPATH=<pkg.steamcompattool> umu-run game.exe（脱离 Steam）
{
  lib,
  stdenvNoCC,
  fetchurl,
  # v3 需要 AVX2/BMI2/FMA（i3-10105 支持）；老 CPU 改 "x86_64"
  variant ? "x86_64_v3",
  version ? "11.0-20261015",
  displayName ? "Proton-CachyOS",
}:

let
  # 与 chaotic-cx/nyx 的 cachyos(-v3)-manifest.json 一致，保证同一份上游 tar.xz
  hashByVariant = {
    x86_64 = "sha256-NeFuq2NnJOPteqji28M+uOEC4MY7vCi1o5r1RMddW9M=";
    x86_64_v3 = "sha256-TxJb19LHJNx9LQVTykLxjGcCKmAG6GKf5/eNFgqevfs=";
  };
  tag = "cachyos-${version}-slr";
in
stdenvNoCC.mkDerivation {
  pname = "proton-cachyos-${variant}";
  inherit version;

  src = fetchurl {
    url = "https://github.com/CachyOS/proton-cachyos/releases/download/${tag}/proton-cachyos-${version}-slr-${variant}.tar.xz";
    hash = hashByVariant.${variant} or (throw "proton-cachyos: 未知 variant '${variant}'");
  };

  # 与 nixpkgs 的 proton-ge-bin 同构：只对外暴露 steamcompattool
  outputs = [
    "out"
    "steamcompattool"
  ];
  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    echo "Proton-CachyOS：请用 programs.steam.extraCompatPackages 或 PROTONPATH 使用。" > $out

    # 上游 tarball 顶层为 proton-cachyos-<ver>-slr-<arch>/，剥一层
    mkdir -p $steamcompattool
    tar -C $steamcompattool --strip-components=1 -xf $src
    chmod +x $steamcompattool/proton

    # Steam 兼容性下拉框里的显示名
    if [ -f $steamcompattool/compatibilitytool.vdf ]; then
      substituteInPlace $steamcompattool/compatibilitytool.vdf \
        --replace-quiet "proton-cachyos-${version}-slr-${variant}" "${displayName}"
      substituteInPlace $steamcompattool/compatibilitytool.vdf \
        --replace-quiet "Proton-CachyOS ${variant}" "${displayName}"
    fi

    runHook postInstall
  '';

  meta = {
    description = "Proton-CachyOS (SLR / Steam Linux Runtime build) 兼容层";
    homepage = "https://github.com/CachyOS/proton-cachyos";
    license = lib.licenses.bsd3;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
