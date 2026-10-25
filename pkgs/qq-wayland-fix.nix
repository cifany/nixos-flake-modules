# QQ（Linux 原生版）+ linuxqq-wayland-fix —— 两个包，一个文件
#
# 为什么不用 nixpkgs 的 pkgs.qq：
#   nixpkgs 26.05 里 qq 的 deb 直链（3.2.29）已被腾讯下架，404。
#   这里复刻 unstable 的做法：向腾讯的签名接口换一个临时直链再下载 3.2.34。
#   代价是要固定 outputHash（内容寻址），腾讯一改包就得换 hash。
#
# 为什么 linuxqq-wayland-fix 也自己打包：
#   上游是独立 flake，但真正有用的只有 nix/package.nix 一个文件。
#   这里拉源码 + callPackage 它，用家就不用额外挂一个 input。
#   版本串用 rev 前 7 位（上游没有 VERSION 文件，版本只在 git tag 里）。
#
# 不含任何用户数据：QQ 的登录态在 ~/.config/QQ，跟包无关，也不会进 store。
{
  lib,
  callPackage,
  fetchFromGitHub,
  runCommandLocal,
  curl,
  jq,
  cacert,
  qq,                     # 用 nixpkgs 的 qq 当模板（它的 unpack/install 逻辑是对的）
  qqVersion ? "3.2.34-2026-09-24",
  qqUrl ? "https://qqdl.gtimg.cn/qqfile/QQNTV2/9.9.36/release/9ee04bef/QQ_3.2.34_260924_amd64_01.deb",
  qqHash ? "sha256-Q2xl4d0oQi4SiiHL3bX+Ti5sB51/J/7CVB4BTTjMM24=",
  waylandFixRev ? "353f91c0d6eb12748904723380efe083f6e071dd",
  waylandFixHash ? "sha256-Xzugw9xzVKU0JtFOFIlRqPFOUSJW+Jes1+UWgK2m9hc=",
}:

let
  # ① QQ 本体：向腾讯签名接口换临时直链，再下载
  #    outputHashMode="flat" 让产物就是「那个 deb 文件本身」，
  #    下游 qq.overrideAttrs 拿到的 src 就是一个 .deb，nixpkgs 的 unpackPhase 直接能用。
  qqSrc = runCommandLocal "QQ_3.2.34_260924_amd64_01.deb" {
    outputHash = qqHash;
    outputHashMode = "flat";
    nativeBuildInputs = [ curl jq cacert ];
  } ''
    # https://github.com/flathub/com.qq.QQ/issues/274#issuecomment-5512982615
    signedUrl=$(curl -fsS --retry 3 \
      -X POST "https://im.qq.com/http2rpc/gotrpc/noauth/trpc.qqntv2.urlsign.UrlSign/GetSign" \
      -H "Content-Type: application/json" \
      -H 'x-oidb: {"uint32_command":"0x9b8e","uint32_service_type":1}' \
      -d '{"url":"${qqUrl}"}' | jq -er '.data.url')
    curl -fL --retry 3 -o "$out" "$signedUrl"
  '';

  qqPkg = qq.overrideAttrs (_old: {
    version = qqVersion;
    name = "qq-${qqVersion}";
    src = qqSrc;
  });

  # ② linuxqq-wayland-fix：拉源码，用它自己的 package.nix 构建
  waylandFixSrc = fetchFromGitHub {
    owner = "SHORiN-KiWATA";
    repo = "linuxqq-wayland-fix";
    rev = waylandFixRev;
    hash = waylandFixHash;
  };

  # 上游 package.nix 的 qqPackage 参数刻意不叫 qq（避免 callPackage 自动填 pkgs.qq），
  # 这里显式传我们这份 qqPkg —— 它会把 QQ 路径写进启动器的
  # QQ_WAYLAND_FIX_QQ / QQ_WAYLAND_FIX_QQ_ROOT，并补上 LD_LIBRARY_PATH、
  # EGL_PLATFORM、VK_DRIVER_FILES 那一堆 NixOS 上必须的东西。
  waylandFix = callPackage "${waylandFixSrc}/nix/package.nix" {
    source = waylandFixSrc;
    version = "unstable-${builtins.substring 0 7 waylandFixRev}";
    qqPackage = qqPkg;
  };
in
{
  # 返回 attrset：调用方按需取（两个包互不覆盖，flake 里分别暴露成
  # packages.qq / packages.qq-wayland-fix）
  inherit qqPkg waylandFix qqSrc waylandFixSrc;

  # 方便 `nix build .#qq-wayland-fix` 直接出那个启动器
  default = waylandFix;
}
