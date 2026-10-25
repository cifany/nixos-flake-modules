# uu-remote-linux 打包说明

网易 UU 远程的第三方 Linux 被控端。上游只发 deb 和预编译 tarball —— 那些 ELF 按 Ubuntu 的
glibc / ffmpeg 链出来，NixOS 上塞不进 store，所以只能按源码编。

## 文件

| 文件 | 作用 |
|---|---|
| `pkgs/uu-remote-linux.nix` | 包定义（Rust + c_engine/ 下一段 C） |
| `pkgs/uu-remote-linux-fixes.patch` | 编解码 / 音频 / VAAPI 四个坑的修复 |
| `pkgs/uu-remote-linux-h264.patch` | 强制 H.264 的补充 |
| `modules/uu-remote.nix` | systemd 用户 unit + `/dev/uinput` 的 uaccess 标签 |

## 依赖锁定的选择

不用 `cargoHash` —— 那是个 FOD，得先编一遍才知道哈希，第一次必然失败。
改用 `cargoLock.lockFile`：`importCargoLock` 按 `Cargo.lock` 里每个 crate 的 checksum
逐个 fetchurl，**求值就能过**。

`Cargo.toml` 里 `[patch.crates-io]` 那三个 path 依赖（`vendor/webrtc*`，上游改过数据通道
与 SRTP 逻辑）在 lock 里没有 source，不进 vendor 目录，cargo 直接读源码树里的。

## 为什么只编 wayland 后端

本机是 niri（wlroots），X11 / portal 后端都用不上；portal 后端还要 libei ≥ 1.1，
且只服务 GNOME/KDE Wayland。控制端 `uuremote-viewer` 不编（要 FFmpeg 6 的开发库）。

**X11 那几个库摘不掉**：`build.rs` 是无条件编 `x11_engine.c` 并
`-lX11 -lXext -lXtst -lXfixes` 的（`clipboard.c` 还要 Xfixes），所以它们是链接期硬依赖。
但它们只在 X11 会话里被调用 —— 纯 wayland 下后端由运行时自选
（`doctor` 里 `selected backend = Wayland`），走 wlr-screencopy / virtual-pointer 原生协议，
一个 X 请求都不会发。

## 四个补丁（都是实测出来的）

1. `UU_VIDEO_CODEC` 只管初始协商；控制端中途请求 H.265 会把它覆盖掉。
2. 没有「强制 H.264 后不再切」的判断，切过去就断流。
3. 音频 pipe 直连时 `-f pulse` 会丢样，但 Ogg granule 仍按墙钟推进：
   实测时间戳比音频内容快 2.9%~12%，控制端 jitter buffer 因此周期性断帧，
   听感就是爆音/杂音，音画不同步越积越多。补 `aresample=async=1`。
4. VAAPI 用 VBR + qmin 控码率，每个 IDR 都被量化得比后续 P 帧狠，
   静止桌面于是每 30 帧（一个 GOP）亮度跳一次，观感是「屏幕一直变色/闪」。
   实测同一像素 R 在 219↔239 来回，B 通道 212→236。改 ICQ 后 0 次变化。

只动 `capture_setting.rs` / `audio.rs` / `video.rs`，不碰协议和编解码逻辑。

## 运行时依赖

代码里是裸的 `Command::new("ffmpeg")` 之类，所以 `wrapProgram` 补 PATH：

- `ffmpeg_7` 编码 + 推流（NVIDIA 卡自动换 h264_nvenc；Intel 核显走 libx264 软编，
  因为上游的进程内 VAAPI 编码只支持 X11 会话）
- `pulseaudio`（pactl）/ `wireplumber`（pw-cli）抓系统声音、被控期间静音本机
- `wl-clipboard` Wayland 剪贴板双向同步
- `pciutils`（lspci）上报显卡型号，决定给控制端什么画质档

`xrandr` 那套故意不带：本机纯 wayland，分辨率由编码器缩放、刷新率上报默认 60
（要真值就 `services.uuremote.environment.UU_DISPLAY_FPS = "75"`）。

`systemctl` / `loginctl` / `timeout` 也不放这儿 —— NixOS 给用户 unit 的默认 PATH 里就有。

## 实测

```bash
nix build github:cifany/nixos-flake-modules#uu-remote-linux
$(nix build --no-link --print-out-paths github:cifany/nixos-flake-modules#uu-remote-linux)/bin/uuremote-server doctor
```

```
version                v0.2.26 x86_64
glibc                  2.42
build features         wayland
selected backend       Wayland
/dev/uinput            writable
ffmpeg version         7.1.5
config mode            600
signed in              true
```

## 二进制缓存

闭包 1.1 GiB / 365 个 store path，源码编一次几分钟。签名缓存 284 MB：
见 [Release uu-remote-0.2.26](https://github.com/cifany/nixos-flake-modules/releases/tag/uu-remote-0.2.26)。

公钥在 `docs/uu-remote-cache.pub`。私钥在仓库外（`keys/` 已 gitignore）。

```bash
nix copy --from "file://$PWD/uu-cache-signed" --to /nix/store \
  --trusted-public-keys "uu-remote-cache-1:4fYQfg0f0tnVLZjB3oqoF7FfFdfZP6hpyC5+NDNdI7g=" \
  /nix/store/8avbkig3d4xpfjjsdsbyjd4i39my5s8l-uu-remote-linux-0.2.26
```

## 不含用户数据

- 产物只有 `uuremote-server` + desktop 文件 + 图标
- 登录凭据在 `~/.config/uuremote/config.json`（0600），跟包无关
- 模块里没有写死任何用户名 / 家目录 / token
