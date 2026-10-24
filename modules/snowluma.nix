# 接入 SnowLuma：把本机 QQ 变成一个 OneBot v11 服务，喂给麦麦或别的机器人
# 程序包本体见 ../pkgs/snowluma.nix（官方预编译 lite 包 + nixpkgs 的 nodejs）
# 关键点（都是官方「Linux 手动部署（进阶）」里列的，缺一个就跑不起来）：
#   · 登录只能扫码，所以必须有一套「无头 X 桌面 + VNC/noVNC」让你看到 QQ 窗口
#   · hook 是靠 ptrace 往 QQ 进程里注入的，官方教程让你 setcap 给 node
#     —— Nix store 只读，setcap 根本写不进去；改用 systemd 的
#     AmbientCapabilities=CAP_SYS_PTRACE，等效且更干净
#   · QQ 有静默热更新通道，会在后台改字节把 native hook 打坏，必须把
#     qqpatch.gtimg.cn black-hole 掉（blockQqHotUpdate）
#   · Xvfb → 窗口管理器 → VNC → QQ → SnowLuma 必须共享同一个 DISPLAY、顺序不能反，
#     所以整条链路塞进一个 unit，停止时按 cgroup 一起收
{ config, lib, pkgs, ... }:

let
  cfg = config.services.snowluma;
  inherit (lib) optional optionals;

  stack = pkgs.writeShellScript "snowluma-stack" ''
    set -eu
    export DISPLAY=:1

    # ① 虚拟屏幕
    ${pkgs.xvfb}/bin/Xvfb :1 -screen 0 ${cfg.screen} -nolisten tcp &
    xvfb_pid=$!
    trap 'kill "$xvfb_pid" 2>/dev/null || true' EXIT INT TERM
    # 别盲等：等 X 的 socket 真的出来
    for _ in $(seq 1 50); do [ -S /tmp/.X11-unix/X1 ] && break; sleep 0.2; done

    # ② 窗口管理器：没有它 QQ 的登录框会没边框/抢不到焦点
    ${pkgs.fluxbox}/bin/fluxbox >/dev/null 2>&1 &

    # ③ VNC + noVNC：只在本机监听 5900，浏览器那侧走 noVNC
    ${pkgs.x11vnc}/bin/x11vnc -display :1 -localhost -forever -shared -quiet \
      ${if cfg.vnc.passwordFile != null then "-rfbauth ${cfg.vnc.passwordFile}" else "-nopw"} &

    ${lib.optionalString cfg.vnc.enable ''
      ${pkgs.novnc}/bin/novnc --vnc 127.0.0.1:5900 --listen ${cfg.vnc.listenAddress}:${toString cfg.vnc.novncPort} &
    ''}

    # ④ QQ 本体：无头环境必须关沙箱/GPU，否则 Chromium 起不来
    # Chromium 的内存开关：限制渲染进程数、限制 JS 堆、别用 /dev/shm 大文件、
    # 关掉窗口遮挡计算（无头环境里它只是白烧 CPU/内存）
    ${lib.getExe' cfg.qq "qq"} --no-sandbox --disable-gpu \
      --disable-software-rasterizer --disable-gpu-compositing \
      --renderer-process-limit=2 --js-flags=--max-old-space-size=256 \
      --disable-dev-shm-usage --disable-features=CalculateNativeWinOcclusion &

    # ⑤ 前台跑 SnowLuma（它负责注入和 WebUI）
    exec ${lib.getExe cfg.package}
  '';
in
{
  options.services.snowluma = {
    enable = lib.mkEnableOption "SnowLuma（QQ → OneBot v11 网关）";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/snowluma.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ../pkgs/snowluma.nix { }";
      description = "SnowLuma 程序包（官方 lite tarball）";
    };

    qq = lib.mkOption {
      type = lib.types.package;
      # hook 与 QQ 版本强绑定：3.2.34 上群聊能注入但「好友私聊上报」是 status=-1，
      # 收不到私聊；SnowLuma 官方镜像钉的就是 3.2.32，所以这里默认用它
      default = pkgs.callPackage ../pkgs/qq-3.2.32.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ../pkgs/qq-3.2.32.nix { }";
      description = ''
        被注入的 QQ 客户端。默认用 3.2.32（与 SnowLuma hook 版本对齐，见 ../pkgs/qq-3.2.32.nix）；
        桌面自己用的 pkgs.qq 仍是 3.2.34，两者互不影响。
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/srv/bots/snowluma";
      description = ''
        数据目录（和麦麦一起放在 /srv/bots 下）：
        config/（含 onebot_<uin>.json）、logs/、home/（QQ 自己的 HOME）、run/
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "snowluma";
      description = "运行整套服务的系统用户";
    };

    screen = lib.mkOption {
      type = lib.types.str;
      default = "1280x720x16";
      description = "Xvfb 虚拟屏幕规格（扫码够看就行；分辨率越大 QQ 的 Chromium 越吃内存）";
    };

    webui = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "WebUI 监听地址；要从别的机器访问改成 0.0.0.0 并打开 openFirewall";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 5099;
        description = "WebUI 端口";
      };
    };

    onebot = {
      httpPort = lib.mkOption {
        type = lib.types.port;
        default = 3000;
        description = "OneBot v11 HTTP 端口（麦麦那侧填这个）";
      };
      wsPort = lib.mkOption {
        type = lib.types.port;
        default = 3001;
        description = "OneBot v11 正向 WebSocket 端口";
      };
    };

    vnc = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          是否常驻 x11vnc + noVNC。只在「需要扫码看 QQ 界面」时才有用，
          所以默认关掉（省 ~70MB）；要扫码时临时开：
            services.snowluma.vnc.enable = true;  然后 switch，扫完再关
        '';
      };
      listenAddress = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = ''
          noVNC 监听地址。默认只听本机（配合 ssh -L 6081:127.0.0.1:6081 就够了）；
          要从别的机器扫码才改 "0.0.0.0"，且务必同时设 vnc.passwordFile。
        '';
      };
      novncPort = lib.mkOption {
        type = lib.types.port;
        default = 6081;
        description = "noVNC 端口（浏览器开 http://<ip>:6081/vnc.html）";
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          VNC 密码文件，用 x11vnc -storepasswd 生成（内容是加密后的 8 位以内的密码）。
          默认 null = 不设密码，此时 noVNC 只允许监听 127.0.0.1。
        '';
      };
    };

    acceptAgreements = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        开启即在启动时同意上游 EULA.md / PRIVACY.md（用 SNOWLUMA_ACCEPT_EULA /
        SNOWLUMA_ACCEPT_PRIVACY 环境变量代劳 WebUI 里的勾选）。
      '';
    };

    blockQqHotUpdate = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        QQ 会静默热更新，把和 native hook 对齐的版本悄悄换掉，注入就废了。
        这里把 qqpatch.gtimg.cn 指到 0.0.0.0（官方手动部署文档第 5 步）。
      '';
    };

    memoryHigh = lib.mkOption {
      type = lib.types.str;
      default = "1100M";
      description = "超过就优先回收（不杀进程）";
    };

    memoryMax = lib.mkOption {
      type = lib.types.str;
      default = "1500M";
      description = "硬上限，超了 OOM 杀；QQ + node 正常在 900MB 上下";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "放行 WebUI / OneBot / noVNC 端口（默认只本机可用，别裸奔到公网）";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.vnc.listenAddress == "127.0.0.1" || cfg.vnc.passwordFile != null;
        message = "services.snowluma：noVNC 一旦监听非本机地址就必须设置 vnc.passwordFile，否则你的 QQ 桌面在网络上裸奔。";
      }
    ];

    users.groups.${cfg.user} = { };
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.user;
      home = "${cfg.dataDir}/home";
      description = "SnowLuma 服务账号";
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.user} -"
      "d ${cfg.dataDir}/home 0750 ${cfg.user} ${cfg.user} -"
      "d ${cfg.dataDir}/run 0700 ${cfg.user} ${cfg.user} -"
    ];

    systemd.services.snowluma = {
      description = "SnowLuma（QQ → OneBot v11 网关）";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      # dbus-run-session 得在 PATH 里找到 dbus-daemon（systemd 的默认 PATH 里没有）
      path = [ pkgs.dbus ];

      environment = {
        HOME = "${cfg.dataDir}/home";
        XDG_RUNTIME_DIR = "${cfg.dataDir}/run";
        TZ = config.time.timeZone;
        SNOWLUMA_WEBUI_HOST = cfg.webui.host;
        SNOWLUMA_WEBUI_PORT = toString cfg.webui.port;
        SNOWLUMA_ONEBOT_HTTP_PORT = toString cfg.onebot.httpPort;
        SNOWLUMA_ONEBOT_WS_PORT = toString cfg.onebot.wsPort;
        # 扫码登录完自动切到工作模式
        SNOWLUMA_HOOK_AUTOLOAD = "1";
        SNOWLUMA_ACCEPT_EULA = lib.mkIf cfg.acceptAgreements "1";
        SNOWLUMA_ACCEPT_PRIVACY = lib.mkIf cfg.acceptAgreements "1";
      };

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.user;
        WorkingDirectory = cfg.dataDir;

        # 整条 X/VNC/QQ/SnowLuma 链路跑在一个 dbus 会话里（Electron 默认会找会话总线）
        ExecStart = "${pkgs.dbus}/bin/dbus-run-session -- ${stack}";

        Restart = "on-failure";
        RestartSec = 15;

        # QQ(Chromium) 没有上限时峰值能冲到 1.5G，这里给个软/硬天花板
        MemoryHigh = cfg.memoryHigh;
        MemoryMax = cfg.memoryMax;

        # hook 靠 ptrace 注入，这是官方 setcap cap_sys_ptrace 的 systemd 等价物
        AmbientCapabilities = [ "CAP_SYS_PTRACE" ];
        CapabilityBoundingSet = [ "CAP_SYS_PTRACE" ];

        # QQ 是 Chromium，需要自己的 /tmp；其余系统目录一律只读
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.dataDir ];
      };
    };

    networking.extraHosts = lib.mkIf cfg.blockQqHotUpdate ''
      0.0.0.0 qqpatch.gtimg.cn
    '';

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall (
      [ cfg.webui.port cfg.onebot.httpPort cfg.onebot.wsPort ]
      ++ optional (cfg.vnc.enable && cfg.vnc.listenAddress != "127.0.0.1") cfg.vnc.novncPort
    );
  };
}
