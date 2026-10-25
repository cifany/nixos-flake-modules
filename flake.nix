{
  description = "cifany 的 NixOS 模块集：MaiBot / SnowLuma / OpenList / Cloudflare Tunnel / Proton-CachyOS / UU 远程 + CachyOS 内核产物";

  inputs = {
    # 钉到具体 rev：别人拉下来不会因为分支移动而重新求值/重新下载
    nixpkgs.url = "github:NixOS/nixpkgs/2efa67fd26b6df417c33e4603185c701f260dd83";

    # CachyOS 内核（BORE 调度 + x86-64-v3）。release 分支是 CI 构建过、有缓存可命中的版本。
    # 刻意不 follows nixpkgs：内核补丁跟 nixpkgs 版本强绑，换掉它自带的 nixpkgs
    # 就缓存不命中，只能本地从头编一个内核。
    nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/b1332396df6e880d7e3b6b451c6a74132ce8cf66";
  };

  outputs = inputs @ { self, nixpkgs, nix-cachyos-kernel, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = [ nix-cachyos-kernel.overlays.pinned ];
      };
      lib = nixpkgs.lib;
    in
    {
      # ── 模块：在自己 flake 里 imports 就能用 ──────────────────────────────
      nixosModules = {
        maibot = import ./modules/maibot.nix;
        snowluma = import ./modules/snowluma.nix;
        openlist = import ./modules/openlist.nix;
        cloudflared-tunnel = import ./modules/cloudflared-tunnel.nix;
        gaming-proton = import ./modules/gaming-proton.nix;
        uu-remote = import ./modules/uu-remote.nix;
        default = { imports = [ ./modules/maibot.nix ./modules/snowluma.nix ]; };
      };

      # ── overlay：把 callPackage 的包塞进 pkgs，自己写模块时 pkgs.maibot 就能用 ──
      overlays.default = final: prev: {
        maibot = final.callPackage ./pkgs/maibot.nix { };
        snowluma = final.callPackage ./pkgs/snowluma.nix { };
        qq_3_2_32 = final.callPackage ./pkgs/qq-3.2.32.nix { };
        # 想直接覆盖 nixpkgs 的 qq 就加这个 overlay：
        #   qq = (final.callPackage ./pkgs/qq-wayland-fix.nix { }).qqPkg;
        qq-wayland-fix = (final.callPackage ./pkgs/qq-wayland-fix.nix { }).waylandFix;
        proton-cachyos = final.callPackage ./pkgs/proton-cachyos.nix { };
        uu-remote-linux = final.callPackage ./pkgs/uu-remote-linux.nix { };
      };

      # ── 包：nix build 直接出产物（也方便 nix copy 进自己的缓存）──────────
      packages.${system} =
        let
          callPkg = f: pkgs.callPackage f { };
        in
        {
          maibot = callPkg ./pkgs/maibot.nix;
          snowluma = callPkg ./pkgs/snowluma.nix;
          "qq-3.2.32" = callPkg ./pkgs/qq-3.2.32.nix;

          # QQ 3.2.34 + Wayland 修复（一个文件出两个包，见 pkgs/qq-wayland-fix.nix）
          qq = (callPkg ./pkgs/qq-wayland-fix.nix).qqPkg;
          qq-wayland-fix = (callPkg ./pkgs/qq-wayland-fix.nix).waylandFix;
          proton-cachyos = callPkg ./pkgs/proton-cachyos.nix;
          uu-remote-linux = callPkg ./pkgs/uu-remote-linux.nix;

          # CachyOS 内核本体（bzImage + System.map + 一份可用的 kernel config）
          # 想复现本机那套：nix build .#cachyos-kernel-artifacts
          cachyos-kernel = pkgs.cachyosKernels.linuxPackages-cachyos-bore-x86_64-v3.kernel;

          cachyos-kernel-artifacts =
            let
              k = pkgs.cachyosKernels.linuxPackages-cachyos-bore-x86_64-v3.kernel;
              m = pkgs.cachyosKernels.linuxPackages-cachyos-bore-x86_64-v3;
            in
            pkgs.runCommandLocal "cachyos-kernel-artifacts-${k.version}" { }
              ''
                mkdir -p $out
                cp ${k}/bzImage $out/bzImage
                cp ${k}/System.map $out/System.map
                cp ${k}/kernel-modules/lib/modules/${k.modDirVersion}/build/.config \
                   $out/config-${k.version} 2>/dev/null \
                  || cp ${m.kernel.dev}/lib/modules/${k.modDirVersion}/build/.config $out/config-${k.version}
                echo "${k.modDirVersion}" > $out/MODULE_VERSION
              '';

          default = callPkg ./pkgs/maibot.nix;
        };

      # ── 现成配置：nixos-rebuild --flake .#example 就能起一套带 bot 的系统 ──
      nixosConfigurations.example = nixpkgs.lib.nixosSystem {
        inherit system;
        # 示例配置里用 inputs.xxx 引用各 input，等价于你自己 flake 里的写法
        specialArgs = { inherit inputs; };
        modules = [
          ./examples/example-configuration.nix
          { nixpkgs.overlays = [ nix-cachyos-kernel.overlays.pinned ]; }
        ];
      };

      # ── 沙盒：nixos-container 用它跑，验证模块能求值能起服务 ──────────────
      nixosConfigurations.sandbox = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = [ ./examples/sandbox-configuration.nix ];
      };

      formatter.${system} = pkgs.nixpkgs-fmt;
    };
}
