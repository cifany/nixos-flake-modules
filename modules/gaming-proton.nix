# 接入 Proton-CachyOS：Steam 兼容工具 + 脱离 Steam 的 umu-launcher 包装
{ config, pkgs, lib, ... }:

let
  proton = pkgs.callPackage ../pkgs/proton-cachyos.nix {
    variant = "x86_64_v3";          # i3-10105 → v3；其他 CPU 改 "x86_64"
    displayName = "Proton-CachyOS";
  };
in
{
  # 32 位图形栈：DXVK d3d9/d3d11 的 32 位路径必需，Steam 模块不会替你开
  hardware.graphics.enable32Bit = true;

  # ① Steam：NixOS 会把它塞进 STEAM_EXTRA_COMPAT_TOOLS_PATHS
  programs.steam.extraCompatPackages = [ proton ];

  # ② 脱离 Steam（Lutris / Heroic / Bottles / 免安装 exe）：
  #    umu-launcher 自带 Steam Runtime（sniper）FHS 容器，等价于 SLR，
  #    不需要 steam-run 手搓，也不会撞 NixOS 的动态库问题。
  environment.systemPackages =
    let
      umuProton = pkgs.writeShellScriptBin "umu-proton-cachyos" ''
        # 用法: umu-proton-cachyos /path/to/game.exe
        #      GAMEID=umu-1234 umu-proton-cachyos game.exe   # 用 umu 数据库里的前缀
        export PROTONPATH="''${PROTONPATH:-${proton.steamcompattool}}"
        export GAMEID="''${GAMEID:-0}"
        exec ${lib.getExe pkgs.umu-launcher} "$@"
      '';

      # 兜底：真要直接跑 proton 本体（无 EAC/BE 的单击游戏），
      # 在 FHS 环境里跑，给它 Steam 需要的几个 STEAM_COMPAT_* 变量。
      protonDirect = pkgs.writeShellScriptBin "proton-cachyos-run" ''
        : "''${STEAM_COMPAT_DATA_PATH:?请设置 STEAM_COMPAT_DATA_PATH（wineprefix 目录）}"
        export STEAM_COMPAT_CLIENT_INSTALL_PATH="''${STEAM_COMPAT_CLIENT_INSTALL_PATH:-$HOME/.local/share/Steam}"
        exec ${pkgs.steam-run}/bin/steam-run ${proton.steamcompattool}/proton run "$@"
      '';
    in
    [
      umuProton
      protonDirect
    ];
}
