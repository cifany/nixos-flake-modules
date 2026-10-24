# 接入 OpenList（原 alist 的分支）：把本机的网盘聚合服务交给 systemd 常驻，开机即起
# 只做两件事：装不装由 §1 的 openlist 包决定，这里只管「怎么常驻」和「工作目录在哪」。
# 关键点（都是踩过才知道的）：
#   · 二进制名是 OpenList（大写 O、大写 L），不是包名 openlist；命令行里直接敲 OpenList。
#   · config.json 里 db_file / log.name / temp_dir / bleve_dir 全是「相对当前工作目录」的
#     路径（data/data.db、data/log/log.log…），不是相对 --data。所以 WorkingDirectory
#     必须是「跑它的那个用户的家目录」，服务起来才落到 ~/data 那套数据上；
#     改成别的目录会另起一套空库。下面 user / workDir 两个选项要配对改。
#   · 它自己会写 data/log/log.log；加 --log-std 让同一份日志也进 journal，
#     排错时不用再去 tail 文件。
#   · 纯网络服务，不依赖图形会话 → 走系统级 unit（User=你的普通用户），不用等登录桌面。
{ config, lib, pkgs, ... }:

let
  cfg = config.services.openlist;
in
{
  options.services.openlist = {
    enable = lib.mkEnableOption "OpenList（网盘聚合 / WebDAV 服务）";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openlist;
      defaultText = lib.literalExpression "pkgs.openlist";
      description = "程序包；版本跟着 nixpkgs 走，要钉版本就在 overlay 里换";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "user";          # ← 改成你自己跑 OpenList 的普通用户
      description = "以谁的身份跑。数据在 ~/data 下，必须是这个家的主人，别改成 DynamicUser";
    };

    workDir = lib.mkOption {
      type = lib.types.str;
      default = "/home/user";    # ← 必须等于 user 选项那个用户的家目录
      description = ''
        工作目录 = config.json 里所有相对路径的基准。
        必须是 user 选项对应的家目录，才能对上 data/config.json + data/data.db；
        换目录等于换一套空数据。
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "data";
      description = "传给 --data 的目录，相对 workDir 解析（默认就是 ~/data）";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        放行 5244。本机自用不用开；要让局域网别的设备直接连再打开。
        走 Cloudflare Tunnel（§12）也不用开 —— 连接是 cloudflared 主动往外打的。
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.openlist = {
      description = "OpenList (file list / WebDAV server)";
      documentation = [ "https://doc.oplist.org/" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        # 相对路径全靠它：db_file=data/data.db、log=data/log/log.log 都在这个目录下解析
        WorkingDirectory = cfg.workDir;
        ExecStart = "${lib.getExe cfg.package} server --data ${cfg.dataDir} --log-std";
        User = cfg.user;
        Group = "users";   # 家目录属于 users 组时才能读写

        # 崩了 5 秒重来；换网络 / 网盘挂载抖动都是靠这条自愈
        Restart = "always";
        RestartSec = 5;
        TimeoutStopSec = 15;

        NoNewPrivileges = true;
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ 5244 ];
  };
}
