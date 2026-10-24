# 接入麦麦（MaiBot）：PyPI 程序包 + 独立实例目录 + systemd 托管
# 程序包本体见 ../pkgs/maibot.nix；官方文档 manual/deployment/update（程序包安装）那条路
# 关键点（都是踩过才知道的）：
#   · 安装版必须用 `maibot run --directory <实例目录>` 启动，配置/数据/插件全在实例目录里，
#     程序目录（/nix/store）只读，正好符合 NixOS 的路子
#   · 第一次启动会阻塞在终端 stdin 上等用户敲「同意」；systemd 下 stdin 不是 tty 会直接 EOF 崩，
#     所以协议确认走 EULA_AGREE / PRIVACY_AGREE 环境变量（值 = 对应 .md 的 md5）
#   · 程序目录在 /nix/store 里只读，内置插件（built_in.plugin-management）想往自己目录写
#     config.toml 会失败，日志里固定一条警告；主功能和 WebUI 不受影响，插件配置在 WebUI 里改
{ config, pkgs, lib, ... }:

let
  cfg = config.services.maibot;

  # 运行时 venv：插件市场装插件时会往 sys.executable 的 site-packages 里 pip install，
  # 而 store 是只读的 —— 所以在数据目录里搭一个可写的 venv 壳子，
  # 主程序自带的包用软链指回 store（只存一份），插件后装的包就落在数据目录里。
  # 每次启动刷新软链，nix 升级后自动指向新的 store 路径。
  prepareVenv = pkgs.writeShellScript "maibot-prepare-venv" ''
    set -eu
    venv=${cfg.dataDir}/venv
    sp=$venv/${cfg.package.sitePackages}
    mkdir -p $venv/bin "$sp"

    # venv 骨架：CPython 靠 sys.executable 同级的 pyvenv.cfg 判定「我在 venv 里」
    ln -sfn ${cfg.package.python.interpreter} $venv/bin/python3.12
    ln -sfn python3.12 $venv/bin/python3
    ln -sfn python3.12 $venv/bin/python
    cat > $venv/pyvenv.cfg <<EOF
    home = ${cfg.package.python}/bin
    include-system-site-packages = false
    version = ${cfg.package.python.version}
    EOF

    # 先清掉上一轮挂的软链（nix 升级后旧路径已经失效），再重新挂；
    # 插件自己 pip 装进来的真实文件/目录一律不动
    find "$sp" -maxdepth 1 -type l -delete
    for entry in ${cfg.package}/${cfg.package.sitePackages}/*; do
      ln -s "$entry" "$sp/$(basename "$entry")"
    done
  '';

  # 用可写 venv 的 python 起主程序（不能再用 store 里那个 console script，
  # 那样 sys.prefix 又回到只读的 store 了）
  runScript = pkgs.writeShellScript "maibot-run" ''
    # 预编译 wheel 自带的动态库放在 site-packages/*.libs/ 里（auditwheel 改过名的
    # libgfortran / libopenblas / libquadmath）。这些 .so 的 RUNPATH 不一定带 $ORIGIN，
    # 而 glibc 的 RUNPATH 不会传给依赖 —— 于是 faiss 找不到 libgfortran、numpy 找不到
    # libstdc++。干脆把所有 *.libs 都塞进 LD_LIBRARY_PATH，来一个算一个。
    sp=${cfg.dataDir}/venv/${cfg.package.sitePackages}
    export LD_LIBRARY_PATH="''${LD_LIBRARY_PATH:-}:$(printf '%s:' "$sp"/*.libs)"
    exec ${cfg.dataDir}/venv/bin/python -m src.cli.tool "$@"
  '';

  # 协议 hash 只能在构建期算（EULA.md 在 store 里，eval 阶段读不到）
  agreements = pkgs.runCommandLocal "maibot-agreements" { } ''
    echo "EULA_AGREE=$(md5sum ${cfg.package.resources}/EULA.md | cut -d' ' -f1)" > $out
    echo "PRIVACY_AGREE=$(md5sum ${cfg.package.resources}/PRIVACY.md | cut -d' ' -f1)" >> $out
  '';
in
{
  options.services.maibot = {
    enable = lib.mkEnableOption "麦麦 MaiBot（基于大模型的 QQ 智能体）";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/maibot.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ../pkgs/maibot.nix { }";
      description = "MaiBot 程序包（PyPI 程序包安装版，自带 venv）";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/srv/bots/maibot";
      description = ''
        实例目录（所有 bot 的数据统一放 /srv/bots/<名字>）：
        config/、data/、logs/、plugins/、temp/、venv/ 都在这里。
        模型配置改 config/model_config.toml，或者直接在 WebUI 里配。
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "maibot";
      description = "运行 MaiBot 的系统用户";
    };

    acceptAgreements = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        开启即视为同意上游 EULA.md 与 PRIVACY.md：启动时用环境变量代劳终端里敲「同意」
        （systemd 的 stdin 不是 tty，交互确认会直接崩）。协议更新后这里会自动跟着变。
        不想代劳就设成 false，自己先手动跑一次 `maibot run --directory <实例目录>` 确认。
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        WebUI 默认只监听 127.0.0.1（bot_config.toml 的 [webui].host），
        要从别的机器访问才需要打开；端口同样以 [webui].port（默认 8001）为准。
      '';
    };

    webuiPort = lib.mkOption {
      type = lib.types.port;
      default = 8001;
      description = "仅用于 openFirewall 放行；真正的端口在实例的 bot_config.toml 里";
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.${cfg.user} = { };
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.user;
      home = cfg.dataDir;
      description = "MaiBot 服务账号";
    };

    # 不用 StateDirectory：那是写死 /var/lib/<name> 的，dataDir 是可改的
    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0750 ${cfg.user} ${cfg.user} -"
    ];

    systemd.services.maibot = {
      description = "MaiBot（麦麦）QQ 智能体";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      # systemd 默认 PATH 里只有 coreutils/findutils/grep/sed（见 unit 的 Environment=），
      # 插件市场装插件、自更新同步代码都要调 git，不显式加上就等于没有
      path = [ pkgs.git pkgs.openssh pkgs.cacert pkgs.uv ];

      environment = {
        PYTHONUNBUFFERED = "1";      # 日志立刻进 journal，别卡在缓冲区
        TZ = config.time.timeZone;   # 程序按 TZ 决定日志/记忆里的时间
        SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        # numpy/pandas 这些预编译 wheel 要 libstdc++、zlib，NixOS 上没 /usr/lib。
        # 程序包里的 console script 有 wrapProgram 兜底，但服务是从运行时 venv
        # 直接起 python 的，所以这里得再来一份（子进程会继承）
        LD_LIBRARY_PATH = lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib pkgs.zlib ];
      };

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.user;
        WorkingDirectory = cfg.dataDir;

        # init 是幂等的：已有 config/*.toml 一律保留，只补 data/logs/plugins/temp
        ExecStartPre = [
          "${lib.getExe cfg.package} init --directory ${cfg.dataDir}"
          "${prepareVenv}"
        ];
        ExecStart = "${runScript} run --directory ${cfg.dataDir}";

        EnvironmentFile = lib.mkIf cfg.acceptAgreements agreements;

        Restart = "on-failure";
        RestartSec = 10;

        # QQ 连接器（NapCat / OneBot）在外面，这里只出网
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ cfg.dataDir ];
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.webuiPort ];
  };
}
