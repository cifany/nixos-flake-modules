# SnowLuma —— QQ 协议框架（OneBot v11），官方只发预编译 tarball
# 用 lite 版：不带 Node 运行时（省 45MB），跑 nixpkgs 的 nodejs；
# native/*.node 是上游预编译 addon（动态链接 libstdc++），靠 autoPatchelfHook 修 RPATH。
# 注意 lite 的 engines 写的是 ^24.22.1 || >=26.12.1，nixpkgs 26.05 只有 24.21.0 ——
# 实测能跑，所以入口直接 `node index.mjs`，跳过 launcher.sh 里那道版本检查。
{ lib
, stdenv
, fetchurl
, nodejs
, makeWrapper
, autoPatchelfHook
, zlib
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "snowluma";
  version = "2.1.1";

  src = fetchurl {
    url = "https://github.com/SnowLuma/SnowLuma/releases/download/v${finalAttrs.version}/SnowLuma-v${finalAttrs.version}-linux-x64-lite.tar.gz";
    hash = "sha256-iomQ4NqH+qLgPBaDvlQdn1MBDcOXSQuMtyAfHx9z0ss=";
  };

  nativeBuildInputs = [ autoPatchelfHook makeWrapper ];
  buildInputs = [ stdenv.cc.cc.lib zlib ];

  # 包里同时塞了 musl 版的 sqlite 预编译件（proot/安卓用），glibc 系统上用不到
  autoPatchelfIgnoreMissingDeps = [ "libc.musl-x86_64.so.1" ];

  # tarball 是「散装」的（./index.mjs、./native/…），没有单一顶层目录
  sourceRoot = ".";
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/snowluma
    cp -r . $out/lib/snowluma/

    # 工作目录是数据目录（config/、logs/ 都相对 cwd 生成），
    # 入口脚本只负责指明 index.mjs 的绝对路径
    makeWrapper ${nodejs}/bin/node $out/bin/snowluma \
      --add-flags "$out/lib/snowluma/index.mjs"

    runHook postInstall
  '';

  meta = {
    description = "SnowLuma —— QQ 协议框架（OneBot v11），把 QQ 会话接进机器人与 AI 工具";
    homepage = "https://github.com/SnowLuma/SnowLuma";
    # 上游声明是 source-available，非 OSI 开源
    license = lib.licenses.unfree;
    mainProgram = "snowluma";
    platforms = [ "x86_64-linux" ];
  };
})
