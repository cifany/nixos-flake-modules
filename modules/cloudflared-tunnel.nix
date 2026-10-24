# 接入 Cloudflare Tunnel（Zero Trust 面板托管，token 模式）
# 只做两件事：把 cloudflared 装进来、用 systemd 常驻一条隧道。别的网络配置一律不碰。
# 关键点（都是踩过才知道的）：
#   · 面板（Zero Trust → Networks → Tunnels）建好隧道后会给你一串 eyJ... 的 token，
#     ingress（哪个域名转到本地哪个端口）全在面板里配；本机不需要 cert.pem、不需要本地
#     ingress 文件，公网入口一个端口都不用开，连接是 cloudflared 主动往外打的。
#   · token 是账号级凭据（拿到就能接管这条隧道），写进 .nix 会随配置落进 /nix/store，
#     那里是全用户可读的 → 所以放 tokenFile，由 LoadCredential 塞进服务的私有凭据目录
#     （/run/credentials/<unit>/，DynamicUser + 目录 0400，只有该服务读得到）。
#   · token 还没填时不能让启动变红：ConditionPathExists 让 unit 在缺文件时静默跳过，
#     nixos-rebuild switch 照常成功；填完 token 再 systemctl start 就上线。
#   · 出网默认 QUIC（UDP 7844）。国内网络把 UDP 打歪时 cloudflared 会自己退回 HTTP/2 over
#     TCP 443，一般不用手改；真要锁死就 extraArgs = [ "--protocol" "http2" ]。
#   · 从面板复制的命令是 `cloudflared service install <token>`，那条会往 /etc/systemd/system
#     写 unit —— NixOS 上会被下一次开关机/重建覆盖。所以这里不跑它，只取 token 走声明式。
{ config, lib, pkgs, ... }:

let
  cfg = config.services.cfTunnel;

  # --metrics 只在配了地址时才传，留空就不加这个参数
  metricsArgs = lib.optionalString (cfg.metricsAddress != null) "--metrics ${cfg.metricsAddress}";
in
{
  options.services.cfTunnel = {
    enable = lib.mkEnableOption "Cloudflare Tunnel 客户端（面板托管 / token 模式）";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.cloudflared;
      defaultText = lib.literalExpression "pkgs.cloudflared";
      description = "客户端包；上游发版频繁，要钉版本就在 overlay 里换";
    };

    tokenFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/cloudflared/tunnel-token";
      description = ''
        存放隧道 token 的文件。刻意不放 /etc/nixos：那样会进 /nix/store。
        写入（一次性，别连着 shell 历史）：
          sudo install -d -m 0700 /etc/cloudflared
          sudo install -m 0400 /dev/stdin /etc/cloudflared/tunnel-token <<< 'eyJ...'
      '';
    };

    edgeIpVersion = lib.mkOption {
      type = lib.types.enum [ "auto" "4" "6" ];
      default = "4";
      description = ''
        跟 Cloudflare 边缘建连用哪个 IP 版本。默认 4：双栈网络里 v6 常被运营商黑洞，
        自动选择会先超时再回退，表现为「启动要等半分钟才连上」。
      '';
    };

    metricsAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "127.0.0.1:20241";
      description = ''
        本地指标/健康检查地址（只监听回环）。curl 127.0.0.1:20241/ready 返回 200
        就说明四条边缘连接都通了。设成 null 就不开。
      '';
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [ "debug" "info" "warn" "error" "fatal" ];
      default = "info";
      description = "TUNNEL_LOGLEVEL；只记连接状态，不打请求体";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--protocol" "http2" ];
      description = "追加到 `cloudflared tunnel` 后面的参数";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "额外环境变量（TUNNEL_* 系列），原样写进 unit";
    };
  };

  config = lib.mkIf cfg.enable {
    # 命令行要能直接用：cloudflared tunnel list / info / tail，排错时不用再 nix shell
    environment.systemPackages = [ cfg.package ];

    systemd.services.cloudflared-tunnel = {
      description = "Cloudflare Tunnel (token, dashboard-managed)";
      documentation = [ "https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      # token 没写之前安静跳过，不让整机 switch 报失败
      unitConfig.ConditionPathExists = cfg.tokenFile;

      environment = {
        TUNNEL_EDGE_IP_VERSION = cfg.edgeIpVersion;
        TUNNEL_LOGLEVEL = cfg.logLevel;
      } // cfg.environment;

      serviceConfig = {
        # token 只在服务自己的凭据目录里出现，进程命令行（ps）看不到
        LoadCredential = [ "tunnel-token:${cfg.tokenFile}" ];
        ExecStart = lib.concatStringsSep " " (
          [
            "${cfg.package}/bin/cloudflared"
            "tunnel"
            "--no-autoupdate"     # 版本由 nix 管，别让它自己下二进制
            metricsArgs
            "run"
            "--token-file"
            "%d/tunnel-token"
          ]
          ++ cfg.extraArgs
        );

        DynamicUser = true;
        # 崩了 5 秒重来；换网络（Wi-Fi/有线切换）也是靠这条自愈
        Restart = "always";
        RestartSec = 5;
        TimeoutStopSec = 15;

        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" ];
      };
    };
  };
}
