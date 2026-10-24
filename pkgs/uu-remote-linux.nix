# uu-remote-linux —— 网易 UU 远程的第三方 Linux 被控端（Rust 主体 + c_engine/ 下一段 C 引擎）
# 上游只发 deb 和预编译 tarball：那些 ELF 是按 Ubuntu 的 glibc / ffmpeg 链出来的，NixOS 上
# 塞不进 store，所以老实按源码编。
# 依赖锁定不用 cargoHash —— 那是个 FOD，得先编一遍才知道哈希，第一次必然失败。改用
# cargoLock.lockFile：importCargoLock 按 Cargo.lock 里每个 crate 的 checksum 逐个 fetchurl，
# 求值就能过。Cargo.toml 里 [patch.crates-io] 那三个 path 依赖（vendor/webrtc*，上游改过
# 数据通道与 SRTP 逻辑）在 lock 里没有 source，不进 vendor 目录，cargo 直接读源码树里的。
# 编的是 wayland 后端：本机是 niri（wlroots），X11 / portal 后端都用不上；portal 后端还要
# libei ≥ 1.1，且只服务 GNOME/KDE Wayland。控制端 uuremote-viewer 不编（要 FFmpeg 6 的开发库）。
# 关于 X11：build.rs 是无条件编 x11_engine.c 并 -lX11/-lXext/-lXtst/-lXfixes 的（clipboard.c 还要
# Xfixes），所以 libX11 那几个是**链接期硬依赖**，摘不掉（摘了要 fork 上游改 build.rs）。
# 但它们只在 X11 会话里被调用：纯 wayland 下后端由运行时自选（doctor 里 selected backend = Wayland），
# 走的是 wlr-screencopy / virtual-pointer 原生协议，一个 X 请求都不会发。
{
  lib,
  rustPlatform,
  fetchFromGitHub,
  fetchurl,
  pkg-config,
  wayland-scanner,
  gtk3,
  wayland,
  libxkbcommon,
  libx11,
  libxext,
  libxtst,
  libxfixes,
  makeWrapper,
  # 服务端只是 fork 一个 ffmpeg 进程出去推流，不链接 FFmpeg 开发库；上游只在 6/7 上验过
  # （8 起 CLI 有改动），它自己会 `ffmpeg -h full` 探测能力，所以保守钉 7
  ffmpeg_7,
  pulseaudio,
  wireplumber,
  wl-clipboard,
  pciutils,
  version ? "0.2.26",
}:

rustPlatform.buildRustPackage (finalAttrs: {
  pname = "uu-remote-linux";
  inherit version;

  src = fetchFromGitHub {
    owner = "VallierDev";
    repo = "uu-remote-linux";
    tag = "v${finalAttrs.version}";
    hash = "sha256-l40XmC0o5QI//vWpeh686EqjU8xofErqCxjBkriLrL8=";
  };

  # 上游的三个坑（见 pkgs/uu-remote-linux-fixes.patch）：
  #   1. UU_VIDEO_CODEC 只管初始协商；控制端中途请求 H.265 会把它覆盖掉
  #   2. 没有「强制 H.264 后不再切」的判断，切过去就断流
  #   3. 音频 pipe 直连时 `-f pulse` 会丢样，但 Ogg granule 仍按墙钟推进：
  #      实测时间戳比音频内容快 2.9%~12%，控制端的 jitter buffer 因此周期性断帧，
  #      听感就是爆音/杂音，而且音画不同步会越积越多。补一个 aresample=async=1。
  #   4. VAAPI 用 VBR + qmin 控码率，每个 IDR 都被量化得比后续 P 帧狠，
  #      静止桌面于是每 30 帧（一个 GOP）亮度跳一次，观感是「屏幕一直变色/闪」。
  #      实测同一个像素的 R 在 219↔239 之间来回，B 通道 212→236。改成 ICQ 后 0 次变化。
  # 只动 capture_setting.rs / audio.rs / video.rs，不碰协议和编解码逻辑。
  patches = [ ./uu-remote-linux-fixes.patch ];

  # 只从上游借这一个文件来 vendor（见文件头：这样就不用 cargoHash）
  cargoLock.lockFile = fetchurl {
    url = "https://raw.githubusercontent.com/VallierDev/uu-remote-linux/v${finalAttrs.version}/Cargo.lock";
    hash = "sha256-5I7JNn9bU6BU6s5DuoX0DUB2G527eSJRzKpgwVqGZnE=";
  };

  # build.rs 用 pkg-config 探测依赖：X11 那四个是硬需求（x11_engine.c / clipboard.c），
  # gtk+-3.0 装了才会编出扫码登录窗口（否则 login 只有终端版）；
  # wayland-scanner 在构建期生成 wlr-screencopy / virtual-pointer 等协议代码
  nativeBuildInputs = [
    pkg-config
    wayland-scanner
    makeWrapper
  ];

  buildInputs = [
    libx11
    libxext
    libxtst
    libxfixes
    gtk3
    wayland
    libxkbcommon
  ];

  buildFeatures = [ "wayland" ];

  # 上游 CI 的测试要现成的 X11 / ffmpeg 环境，在 Nix 沙箱里跑不起来；编译通过即可
  doCheck = false;

  postInstall = ''
    install -Dm644 contrib/desktop/uu-remote-linux.desktop -t $out/share/applications
    install -Dm644 contrib/desktop/uu-remote-linux.svg -t $out/share/icons/hicolor/scalable/apps
  '';

  # 运行时靠这些外部程序干活（代码里是裸的 Command::new("ffmpeg") 之类）：
  #   ffmpeg      编码 + 推流（NVIDIA 卡自动换 h264_nvenc；本机是 Intel 核显 → 走 libx264 软编，
  #               因为上游的进程内 VAAPI 编码（inproc-av）只支持 X11 会话）
  # X11 的两个工具（xrandr 改分辨率、读刷新率）故意不带：本机纯 wayland，
  # 分辨率由编码器缩放、刷新率上报默认 60（要真值就 services.uuremote.environment.UU_DISPLAY_FPS = "75"）
  #   pactl/wpctl 抓系统声音、被控期间静音本机
  #   wl-copy/wl-paste  Wayland 剪贴板双向同步
  #   lspci       上报显卡型号（决定给控制端什么画质档）
  # systemctl / loginctl / timeout 不放这儿 —— NixOS 给用户 unit 的默认 PATH 里就有，见 modules/uu-remote.nix
  postFixup = ''
    wrapProgram $out/bin/uuremote-server \
      --prefix PATH : ${lib.makeBinPath [ ffmpeg_7 pulseaudio wireplumber wl-clipboard pciutils ]}
  '';

  meta = {
    description = "网易 UU 远程的第三方 Linux 被控端（官方 Mac / Windows / 手机端可远控本机）";
    homepage = "https://github.com/VallierDev/uu-remote-linux";
    license = lib.licenses.gpl3Plus;
    mainProgram = "uuremote-server";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
})
