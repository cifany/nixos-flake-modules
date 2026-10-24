# 沙盒系统：专门用来验证本仓库的模块能不能求值、服务能不能起来。
# 用法见 README「沙盒测试」。只装模块，不碰宿主机任何配置。
{ config, lib, pkgs, modulesPath, inputs, ... }:

{
  imports = [
    (modulesPath + "/profiles/minimal.nix")
    # 刻意走「远端拉取」这条路径，验证别人 clone 下来能求值 —— 而不是用本地相对路径
    inputs.self.nixosModules.maibot
    inputs.self.nixosModules.snowluma
    inputs.self.nixosModules.openlist
    inputs.self.nixosModules.cloudflared-tunnel
    inputs.self.nixosModules.uu-remote
  ];

  # 容器里没有真实硬件，内核模块/udev 相关的断言用不到
  boot.loader.grub.enable = false;
  fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
  system.stateVersion = "26.05";

  nixpkgs.config.allowUnfree = true;

  # ── 真正启用的只有这两个，剩下的靠「import 成功」证明可求值 ──────────────
  services.openlist = {
    enable = true;
    user = "root";
    workDir = "/root";
  };

  services.cfTunnel = {
    enable = true;
    tokenFile = "/etc/cloudflared/tunnel-token";   # 沙盒里没这个文件 → unit 静默跳过
  };

  # 这两个默认开启会拉 GB 级下载/需要图形会话，沙盒里保持关闭但模块仍被求值：
  services.maibot.enable = false;
  services.snowluma.enable = false;
  services.uuremote.enable = false;

  # 让 nixos-container 里的服务日志能直接看
  systemd.services.openlist.environment.TZ = "Asia/Shanghai";
}
