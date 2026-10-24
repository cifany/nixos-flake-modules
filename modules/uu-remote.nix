# 接入 uu-remote-linux：把本机变成 UU 远程的被控端（官方 Mac / Windows / 手机端直接连进来）
# 程序包本体见 ../pkgs/uu-remote-linux.nix；这里只管「怎么在图形会话里常驻」和系统侧那点权限。
# 要点：
#   · 它是个用户级进程，必须活在图形会话里。unit 名不能改：桌面图标的「打开主窗口」
#     （uuremote-server show）和 `uuremote-server doctor` 都按 uuremote-native.service
#     这个名字去 systemctl --user 找，改了就成了两个互不相认的进程。
#   · niri 是 wlroots 合成器 → 走包的 wayland 后端；niri.service 是 BindsTo=graphical-session.target
#     并且 niri-session 会 import-environment（WAYLAND_DISPLAY 进用户管理器），所以
#     WantedBy=graphical-session.target 就能拿到合成器和环境变量。
#     WAYLAND_DISPLAY 由 niri 带 systemd 集成时主动 set-environment 写回，这里不用手动传。
#   · Wayland 下键鼠注入默认要过 portal 授权，部分布局还会丢符号（下划线变别的）。
#     给 /dev/uinput 打 uaccess 标签后服务改用内核级虚拟键鼠、发物理键码，布局无关。
#     用 uaccess 而不是 hardware.uinput 的 uinput 用户组：前者的 ACL 跟着「本地活跃会话」走，
#     注销即失效；后者是常驻组成员，权限面更大。
#   · 登录只能扫码，而且要图形桌面：首次 `uuremote-server login`（弹二维码窗口）扫一次，
#     凭据写在 ~/.config/uuremote/config.json（0600），之后服务自己上线。
#   · 排错：journalctl --user -u uuremote-native.service -f；uuremote-server doctor
{ config, lib, pkgs, ... }:

let
  cfg = config.services.uuremote;
in
{
  options.services.uuremote = {
    enable = lib.mkEnableOption "uu-remote-linux（非官方 UU 远程被控端）";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/uu-remote-linux.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ../pkgs/uu-remote-linux.nix { }";
      description = "程序包（上游源码 + cargoLock 离线 vendor，带 wayland 后端）";
    };

    uinput = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        允许本地图形会话读写 /dev/uinput（udev 的 uaccess 标签）。
        开了之后服务用内核级虚拟键鼠代替 portal 注入，Wayland 下不再受键盘布局影响。
      '';
    };

    logLevel = lib.mkOption {
      type = lib.types.str;
      default = "info";
      description = "RUST_LOG；服务不输出账号 / 令牌 / 按键内容，放心留着 info 看连接状态";
    };

    encoder = lib.mkOption {
      type = lib.types.enum [ "vaapi" "cpu" "nvenc" ];
      default = "vaapi";
      description = ''
        视频编码器。默认 vaapi：上游的 auto 只认 NVIDIA 驱动，Intel/AMD 核显一律落到
        libx264/libx265 软编，1080p60 要吃掉 2-5 个核（实测 libx265 4.7 核 / libx264 1.7 核），
        桌面一忙就抢不到帧 → 观感就是「用一会儿卡死、延迟越来越大」。走核显后 CPU 降到 ~2.6 核，
        帧率稳稳打满 60。
        cpu / nvenc 是逃生舱：核显驱动抽风时回退用。
      '';
    };

    codec = lib.mkOption {
      type = lib.types.enum [ "h264" "h265" ];
      default = "h264";
      description = ''
        强制编码格式。默认 h264：Mac 控制端会主动请求 H.265（抓包日志里 field 13 = 2），
        而上游在「H.265 的 m-line 没协商成功」时不会退回 H.264，直接
        `unable to start track, codec is not supported by remote` 把整条流断掉 ——
        这就是「用一段时间忽然卡死」的另一半原因。H.264 两边都稳。
      '';
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { UU_DESKTOP_RESIZE = "0"; };
      description = ''
        额外环境变量。常用的几个：
          UU_DESKTOP_RESIZE = "0"   X11 下不让控制端改本机分辨率（改成在编码器里缩放）
          UU_PORT_MAPPING   = "0"   关掉「端口映射」工具
          UU_CAPTURE        = "grab"  强制走 X11 抓屏而不是 inproc
      '';
    };

    wantedBy = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "graphical-session.target" ];
      description = ''
        挂到哪个 target 上。也可以学 iNiR 写成 [ "niri.service" ]，顺序上更严格地排在合成器之后。
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # 主要是为了应用菜单里的图标；命令行 (uuremote-server doctor / login) 也用它
    environment.systemPackages = [ cfg.package ];

    systemd.user.services.uuremote-native = {
      description = "UU Remote Linux host (unofficial)";
      documentation = [ "https://github.com/VallierDev/uu-remote-linux" ];
      after = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      wantedBy = cfg.wantedBy;

      # 不用自己拼 PATH：NixOS 给用户 unit 的默认 PATH 里已经有 coreutils + systemd，
      # 而「锁定 / 重启 / 关机 / doctor」调的就是 systemctl、loginctl、timeout。
      # ffmpeg / xrandr / pactl / wl-copy 那些在包的 wrapper 里（见 pkgs/uu-remote-linux.nix）。

      serviceConfig = {
        ExecStart = "${lib.getExe cfg.package}";
        Environment = [
          "RUST_LOG=${cfg.logLevel}"
          "UU_VIDEO_ENCODER=${cfg.encoder}"
          "UU_VIDEO_CODEC=${cfg.codec}"
        ]
          ++ lib.optional (config.time.timeZone != null) "TZ=${config.time.timeZone}"
          ++ lib.mapAttrsToList (name: value: "${name}=${value}") cfg.environment;
        # 上游单元就是这两条：崩了 5 秒后重来；从托盘「退出」是它自己 systemctl --user stop，
        # 走的是幂等的 stop 路径，不会被这里再拉起来
        Restart = "always";
        RestartSec = 5;
      };
    };

    boot.kernelModules = lib.mkIf cfg.uinput [ "uinput" ];
    # 上游文档的第 5 步，原样搬过来（static_node 让 /dev/uinput 在没人用时也存在）
    services.udev.extraRules = lib.mkIf cfg.uinput ''
      KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", TAG+="uaccess"
    '';
  };
}
