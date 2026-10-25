# 最小可用示例：把本仓库的模块接进自己的 NixOS 配置。
# 用法：把本文件拷进你的 /etc/nixos，然后在 flake.nix 里按 README「拉取配置」一节挂 inputs。
{ config, lib, pkgs, inputs, ... }:

{
  # 这段是让本文件能单独求值（flake 里 nixosConfigurations.example 要它）；
  # 真接进你自己的配置时删掉下面三行，用你 hardware-configuration.nix 里的值。
  fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # QQ / SnowLuma 是 unfree（上游 source-available），不开这个求值就报错
  nixpkgs.config.allowUnfree = true;

  # 按需挑：不用的模块删掉那一行就行，互不依赖。
  # inputs.self 指本仓库，等价于你 flake 里的 inputs.nixos-flake-modules
  imports = [
    inputs.self.nixosModules.maibot
    inputs.self.nixosModules.snowluma
    inputs.self.nixosModules.openlist
    inputs.self.nixosModules.cloudflared-tunnel
    inputs.self.nixosModules.gaming-proton
    inputs.self.nixosModules.uu-remote
  ];

  # ── CachyOS 内核（可选）────────────────────────────────────────────────
  # 内核补丁跟 nixpkgs 版本强绑，所以这个 input 刻意不 follows 你的 nixpkgs，
  # 否则缓存不命中、只能本地从头编一个内核（几小时）。
  boot.kernelPackages = pkgs.cachyosKernels.linuxPackages-cachyos-bore-x86_64-v3;
  nixpkgs.overlays = [
    inputs.nix-cachyos-kernel.overlays.pinned
    # QQ：nixpkgs 26.05 里的 3.2.29 直链已 404，换成 3.2.34。
    # 注意要传 prev.qq 当模板 —— 直接 callPackage 会拿到这个 overlay 正在定义的
    # qq 自己，变成无限递归。
    (final: prev: {
      qq = (final.callPackage "${inputs.self}/pkgs/qq-wayland-fix.nix" {
        qq = prev.qq;
      }).qqPkg;
    })
  ];

  # ── MaiBot（麦麦）─────────────────────────────────────────────────────
  services.maibot = {
    enable = true;
    dataDir = "/srv/bots/maibot";
    # WebUI 默认只听 127.0.0.1；要从别的机器进就开 openFirewall 并改
    # 实例里 config/bot_config.toml 的 [webui].host
    openFirewall = false;
  };

  # ── SnowLuma（QQ → OneBot v11）────────────────────────────────────────
  services.snowluma = {
    enable = true;
    dataDir = "/srv/bots/snowluma";
    # 扫码登录时才临时打开，扫完关掉省 ~70MB 内存
    vnc.enable = false;
  };

  # ── OpenList（网盘聚合 / WebDAV）──────────────────────────────────────
  services.openlist = {
    enable = true;
    user = "youruser";              # ← 改成你自己的普通用户
    workDir = "/home/youruser";     # ← 必须等于上面那个用户的家目录
  };

  # ── Cloudflare Tunnel（公网入口，token 模式）──────────────────────────
  services.cfTunnel = {
    enable = true;
    # token 写进 /etc/cloudflared/tunnel-token（0400），别写进 .nix
    tokenFile = "/etc/cloudflared/tunnel-token";
  };

  # ── QQ + Wayland 修复 ─────────────────────────────────────────────────
  # 两件事：① 把 nixpkgs 的 qq 换成 3.2.34（nixpkgs 里的 3.2.29 直链已 404）；
  #         ② 装上 Wayland 修复启动器（屏幕共享 / 共享电脑声音 / 剪贴板 / 截图闪退）
  environment.systemPackages = [
    inputs.self.packages.${pkgs.system}.qq-wayland-fix
  ];

  # QQ 的屏幕共享走 portal 的 ScreenCast 接口，缺了它共享会失败。
  # niri / Hyprland 这类合成器还要额外启用对应的后端。
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
  };

  # ── Proton-CachyOS + UU 远程被控端 ────────────────────────────────────
  # gaming-proton 只要被 import 就生效（往 Steam 塞兼容工具 + 两个包装脚本）
  services.uuremote = {
    enable = true;
    uinput = true;    # 给 /dev/uinput 打 uaccess 标签，Wayland 下键鼠注入不再受布局影响
  };
}
