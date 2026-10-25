# nixos-flake-modules

cifany 的 NixOS 模块集。每个模块都是「装包 + systemd 常驻 + 踩坑注释」的完整一套，
可以直接 import 进任何 NixOS flake，也可以只抄走 `pkgs/` 里的包定义。

| 模块 | 干什么 | 依赖 |
|---|---|---|
| `maibot` | 麦麦 MaiBot（QQ 智能体），PyPI wheel + 可写 venv + systemd | uv / python312 |
| `snowluma` | SnowLuma（QQ → OneBot v11 网关），Xvfb + VNC + ptrace 注入 | nodejs / QQ |
| `openlist` | OpenList（网盘聚合 / WebDAV），systemd 常驻 | — |
| `cloudflared-tunnel` | Cloudflare Tunnel（token 模式），公网入口不用开端口 | — |
| `gaming-proton` | Proton-CachyOS（Steam 兼容工具 + umu 独立运行） | — |
| `uu-remote` | uu-remote-linux 被控端（Wayland 键鼠注入走 uinput） | — |
| `qq` + `qq-wayland-fix` | QQ 3.2.34 + Wayland 修复（屏幕共享 / 声音 / 剪贴板 / 截图） | — |

外加 CachyOS 内核（BORE 调度 + x86-64-v3）的 overlay 与产物构建。

## 拉取配置

### 1. 加 input

`flake.nix`：

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    nixos-flake-modules = {
      url = "github:cifany/nixos-flake-modules";
      # 模块只用 nixpkgs，跟着你的走，避免求值两份
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # 只有要用 CachyOS 内核才需要这个。
    # 刻意不 follows：内核补丁跟 nixpkgs 版本强绑，换掉它自带的 nixpkgs
    # 就缓存不命中，只能本地从头编一个内核（几小时）。
    nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/release";
  };

  outputs = inputs @ { nixpkgs, nixos-flake-modules, ... }: {
    nixosConfigurations.yourhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit inputs; };   # 配置里要用 inputs.self 就得传
      modules = [
        ./configuration.nix
        ./hardware-configuration.nix
      ];
    };
  };
}
```

### 2. 在你的 configuration.nix 里 import

```nix
{ config, pkgs, inputs, ... }:

{
  imports = [
    inputs.nixos-flake-modules.nixosModules.maibot
    inputs.nixos-flake-modules.nixosModules.openlist
    # 不用的删掉就行，模块之间互不依赖
  ];

  services.maibot.enable = true;
  services.openlist = {
    enable = true;
    user = "youruser";            # ← 改成你自己的普通用户
    workDir = "/home/youruser";   # ← 必须等于上面那个用户的家目录
  };
}
```

完整示例见 [`examples/example-configuration.nix`](examples/example-configuration.nix)。

### 3. 不用 flake 的场合

`pkgs/` 里的包都是普通 `callPackage` 风格，直接抄走即可：

```nix
pkgs.callPackage ./pkgs/maibot.nix { }
```

## 只想要包，不要模块

```bash
# 单包构建
nix build github:cifany/nixos-flake-modules#maibot
nix build github:cifany/nixos-flake-modules#snowluma
nix build github:cifany/nixos-flake-modules#proton-cachyos
nix build github:cifany/nixos-flake-modules#uu-remote-linux
nix build github:cifany/nixos-flake-modules#qq              # QQ 3.2.34（unfree）
nix build github:cifany/nixos-flake-modules#qq-wayland-fix  # 启动器 + 4 个注入库

# CachyOS 内核产物（bzImage + System.map + config + MODULE_VERSION）
nix build github:cifany/nixos-flake-modules#cachyos-kernel-artifacts
```

拿进本地 store（离线的机器也能用）：

```bash
nix copy --from github:cifany/nixos-flake-modules#maibot --to /tmp/nix-cache
```

## 沙盒测试

仓库自带一套沙盒系统，专门验证「模块能不能求值、服务能不能起来」，
不会碰宿主机任何配置：

```bash
# ① 先只求值（最快要几十秒，第一次要拉依赖）
nix eval .#nixosConfigurations.sandbox.config.system.build.toplevel.drvPath

# ② 构建整套系统
nix build .#nixosConfigurations.sandbox.config.system.build.toplevel

# ③ 起一个一次性容器
#    注意：nixpkgs 26.05 的 nixos-container 起不来（containerInit 仍用 `. init`
#    加载 toplevel，而新版 init 已是 ELF），所以这里直接用 systemd-nspawn。
#    完整步骤与原因见 docs/sandbox-test.md
SYS=$(nix build --no-link --print-out-paths .#nixosConfigurations.sandbox.config.system.build.toplevel)
ROOT=/tmp/sbroot
sudo mkdir -p $ROOT/{usr/bin,var/lib,run,tmp,root,proc,sys,dev,etc,var/empty}
sudo chmod 1777 $ROOT/tmp
sudo sh -c "for f in $SYS/etc/*; do ln -sfn \"\$f\" $ROOT/etc/\$(basename \"\$f\"); done"
sudo sh -c "printf 'root:x:0:0:root:/root:/run/current-system/sw/bin/bash\n' > $ROOT/etc/passwd"
sudo sh -c "printf 'root:x:0:\nusers:x:100:\n' > $ROOT/etc/group"
sudo systemd-nspawn -D $ROOT -M sbtest --bind-ro=/nix/store \
  --bind=$SYS:/run/current-system --bind-ro=/nix/var/nix/db \
  --private-network --register=no --keep-unit /run/current-system/init &

# ④ 验证（--register=no 时 machinectl 看不到，用 nsenter 进）
INIT=$(pgrep -f '^/run/current-system/init' | head -1)
sudo nsenter -t $INIT -m -p -i -- systemctl is-active openlist
sudo nsenter -t $INIT -m -p -i -- curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5244

# ⑤ 收工
sudo pkill -f 'systemd-nspawn -D /tmp/sbroot'
sudo rm -rf $ROOT
```

沙盒里默认只开 OpenList（能验证「包能装、服务能起、端口能通」），
MaiBot / SnowLuma / uu-remote 只 import 不求值它们的重量级依赖 —— 那几个动辄几百 MB。

## 模块要点（都是踩过才知道的）

### maibot

- 安装版必须 `maibot run --directory <实例目录>` 启动，配置/数据/插件全在实例目录；
  程序目录在 `/nix/store` 里只读，正好符合 NixOS 的路子。
- 首次启动会阻塞在 stdin 等用户敲「同意」，systemd 下 stdin 不是 tty 会直接 EOF 崩。
  所以协议确认走 `EULA_AGREE` / `PRIVACY_AGREE` 环境变量（值 = 对应 `.md` 的 md5）。
- 插件市场装插件时会往 `sys.executable` 的 site-packages 里 pip install，而 store 只读。
  模块在数据目录里搭一个可写 venv 壳子，主程序的包用软链指回 store（只存一份），
  插件后装的包落在数据目录；每次启动刷新软链，nix 升级后自动指向新路径。
- 预编译 wheel 自带的 `.so` 在 `site-packages/*.libs/`，RUNPATH 不一定带 `$ORIGIN`，
  glibc 的 RUNPATH 又不传给依赖 —— 所以把这些目录全塞进 `LD_LIBRARY_PATH`。

### snowluma

- 登录只能扫码，必须一套无头 X + VNC/noVNC 让你看到 QQ 窗口；
  Xvfb → WM → VNC → QQ → SnowLuma 顺序不能反，所以整条链路塞进一个 unit。
- hook 靠 ptrace 注入。官方教程让你 `setcap` 给 node，但 store 只读写不进去；
  改用 systemd 的 `AmbientCapabilities=CAP_SYS_PTRACE`，等效且更干净。
- QQ 有静默热更新通道，会在后台改字节把 native hook 打坏，
  所以把 `qqpatch.gtimg.cn` black-hole 掉（`blockQqHotUpdate`）。
- hook 与 QQ 版本强绑定：3.2.34 上「好友私聊上报」返回 status=-1，收不到私聊，
  默认钉 3.2.32。

### openlist

- `config.json` 里 `db_file` / `log.name` / `temp_dir` / `bleve_dir` 都是
  「相对当前工作目录」的路径，不是相对 `--data`。
  所以 `WorkingDirectory` 必须是跑它的那个用户的家目录，`user` 和 `workDir` 两个选项要配对改。
- 首次启动才生成 admin 密码，只在日志里打一次：
  `journalctl -u openlist | grep -i "initial password"`。
  已有 `data/data.db` 时不会再打，忘了密码用 `OpenList admin set NEW_PASS`。

### cloudflared-tunnel

- token 是账号级凭据，写进 `.nix` 会随配置落进 `/nix/store`（全用户可读）。
  所以放 `tokenFile`，由 `LoadCredential` 塞进服务私有凭据目录。
- token 没填时不能让启动变红：`ConditionPathExists` 让 unit 在缺文件时静默跳过。
- 从面板复制的 `cloudflared service install <token>` 会往 `/etc/systemd/system` 写 unit，
  NixOS 上会被下次重建覆盖 —— 所以不跑它，只取 token 走声明式。

### gaming-proton

- 上游只发 SLR（Steam Linux Runtime 容器）二进制，native 版只有 AUR 源码包。
- 32 位图形栈必须自己开（`hardware.graphics.enable32Bit`），Steam 模块不会替你开
  DXVK 的 d3d9/d3d11 32 位路径。
- 脱离 Steam 时用 `umu-launcher`（自带 sniper 运行时），不用 `steam-run` 手搓。

### uu-remote

- 是用户级进程，必须活在图形会话里。unit 名不能改：桌面图标和
  `uuremote-server doctor` 都按 `uuremote-native.service` 这个名字去 `systemctl --user` 找。
- Wayland 下键鼠注入默认要过 portal 授权，部分布局还会丢符号。
  给 `/dev/uinput` 打 `uaccess` 标签后改用内核级虚拟键鼠、发物理键码，布局无关。
  用 `uaccess` 而不是 `uinput` 组：前者 ACL 跟着「本地活跃会话」走，注销即失效。

### qq / qq-wayland-fix

- nixpkgs 26.05 里 `pkgs.qq` 的 deb 直链（3.2.29）已被腾讯下架，404。
  这里复刻 unstable 的做法：向腾讯签名接口换一个**临时直链**再下载 3.2.34，
  用 `outputHashMode = "flat"` 固定内容，产物就是那个 `.deb` 本身。
  腾讯一改包就得换 `qqHash`。
- Wayland 修复（`linuxqq-wayland-fix`）通过 `LD_PRELOAD` 注入四个库，
  不改 QQ 自身文件：`libqq-wl-portal.so`（屏幕共享 / 共享设备音频）、
  `libqq-clipbridge.so`（X11 ↔ Wayland 剪贴板）、`libqq-screenshot.so`（截图防闪退）、
  `libqq-borderfix.so`（共享时隐藏全屏边框）。
- 上游 `package.nix` 的 `qqPackage` 参数刻意不叫 `qq` —— `callPackage` 会自动填 `pkgs.qq`。
  所以 overlay 里覆盖 `qq` 时必须显式传 `qq = prev.qq` 当模板，否则无限递归。
- 几个 NixOS 特有的补丁（都在上游 `package.nix` 里，这里只是复用）：
  - `LD_LIBRARY_PATH` 补 pipewire —— `broadcast-core.so` 用裸名 `dlopen("libpipewire-0.3.so.0")`，
    NixOS 没有全局库目录，不补就静默失败（屏幕共享不弹 portal）。
  - `EGL_PLATFORM=wayland` —— 否则 glvnd 把 `EGL_DEFAULT_DISPLAY` 交给 Mesa，
    NVIDIA 闭源驱动下退化成 llvmpipe 软件渲染（实测 12 线程 ~5 个核）。
  - `VK_DRIVER_FILES` 指向 `/run/opengl-driver/share/vulkan/icd.d` —— 上游只找
    `/usr/share/vulkan`，NixOS 上永远探测不到。
  - `LD_LIBRARY_PATH` 追加 `/run/opengl-driver/lib` —— NVENC / AMF / QSV 硬件编解码，
    不补只能落到 OpenH264 软件编码。
- **不含用户数据**：登录态在 `~/.config/QQ`，跟包无关，不会进 store。

接进自己的配置：

```nix
nixpkgs.overlays = [
  (final: prev: {
    qq = (final.callPackage "${inputs.nixos-flake-modules}/pkgs/qq-wayland-fix.nix" {
      qq = prev.qq;      # ← 必须传，否则递归
    }).qqPkg;
  })
];

environment.systemPackages = [
  inputs.nixos-flake-modules.packages.${pkgs.system}.qq-wayland-fix
];

# 屏幕共享走 portal，缺了它共享会失败
xdg.portal.enable = true;
xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
```

### CachyOS 内核

- overlay 必须用 `nix-cachyos-kernel` 自己锁的 nixpkgs 求值，否则缓存不命中。
  这就是这个 input 不能 `follows` 的原因。
- `cache.xinux.uz` 是 CachyOS 内核的镜像缓存（attic 被入侵下线后接的班），
  建议加进 `nix.settings.substituters`。

## uu-remote-linux 二进制缓存

闭包 1.1 GiB（含 ffmpeg / gtk3 / systemd 等），源码编一次几分钟。不想编就用签名缓存：

**[uu-remote-0.2.26](https://github.com/cifany/nixos-flake-modules/releases/tag/uu-remote-0.2.26)**

```bash
curl -LO https://github.com/cifany/nixos-flake-modules/releases/download/uu-remote-0.2.26/uu-remote-cache.tar.xz
tar -xf uu-remote-cache.tar.xz          # → ./uu-cache-signed/
nix copy --from "file://$PWD/uu-cache-signed" --to /nix/store \
  /nix/store/8avbkig3d4xpfjjsdsbyjd4i39my5s8l-uu-remote-linux-0.2.26
```

缓存公钥（`docs/uu-remote-cache.pub`，私钥不在仓库里）：

```
uu-remote-cache-1:4fYQfg0f0tnVLZjB3oqoF7FfFdfZP6hpyC5+NDNdI7g=
```

加进 `nix.settings.trusted-public-keys` 就能免 `require-sigs`。

| 文件 | 大小 | SHA256 |
|---|---|---|
| `uu-remote-cache.tar.xz` | 284 MB | `0e50d5dc…e8c5b` |

## 内核产物

这台机器编出来的 7.2.8 产物在 Release 里（不进 git，150MB+）：

**[kernel-7.2.8-cachyos](https://github.com/cifany/nixos-flake-modules/releases/tag/kernel-7.2.8-cachyos)**

| 文件 | 大小 | SHA256 |
|---|---|---|
| `cachyos-kernel-7.2.8-x86_64-v3.tar.xz` | 16 MB | `256b9c8c…edb559` |
| `modules-7.2.8.tar.xz` | 150 MB | `ff25026f…1e39a3` |

自己构建（推荐，版本一定对得上）：

```bash
nix build github:cifany/nixos-flake-modules#cachyos-kernel-artifacts
ls result/    # bzImage  System.map  config-7.2.8  MODULE_VERSION
```

模块部分（`modules-7.2.8.tar.xz`）体积大且和内核版本强绑，
一般不用单独拷 —— 用同一个 flake 构建出来的系统自带匹配的模块。

## 许可

各模块/包的许可跟上游走：MaiBot 是 AGPL-3.0，SnowLuma 是 source-available（unfree），
Proton-CachyOS 是 BSD-3，其余见各文件 `meta.license`。
本仓库自身的胶水代码随便用。
