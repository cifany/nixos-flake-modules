# 沙盒测试记录

在 2026-10-25 用 systemd-nspawn 跑过一遍，验证的是**远端拉取**这条路径
（`github:cifany/nixos-flake-modules`），不是本地相对路径。

## 环境

- 宿主：NixOS 26.05，内核 7.2.8-cachyos（x86-64-v3）
- 沙盒：nixpkgs 26.05 的 `profiles/minimal.nix` + 本仓库五个模块
- 隔离：`--private-network`（无外网）、`--bind-ro=/nix/store`

## 结果

| 检查项 | 结果 |
|---|---|
| `nix flake metadata github:cifany/nixos-flake-modules` | 通过（rev f6c54a0） |
| 六个 `nixosModules.*` 求值 | 全部 `lambda` |
| `nixosConfigurations.sandbox` 求值 | 通过 |
| `system.build.toplevel` 构建 | 通过 |
| 容器启动到 `multi-user.target` | 通过 |
| `openlist.service` | `active`，`HTTP 200` on `:5244` |
| `cloudflared-tunnel.service` | `inactive (dead)`，`Condition: start condition unmet` ← 缺 token 时静默跳过，符合设计 |
| `maibot` / `snowluma` / `uu-remote` | 只 import 求值，未启用（依赖几百 MB，沙盒里没必要拉） |

## 踩到的坑（nixos-container 不可用）

nixpkgs 26.05 的 `nixos-containers.nix` 里 `containerInit` 仍是：

```sh
set +e
. "$1"          # $1 = /nix/var/nix/profiles/system/init
```

而新版 `system.build.toplevel` 的 `init` 已经是 **ELF 二进制**（不是 stage-2 shell 脚本），
`. ` 加载二进制会报 `cannot execute binary file`，容器起不来。

绕法：直接用 `systemd-nspawn`，指定 `/run/current-system/init` 当 PID 1，
并且把 `/etc` 下的文件逐个软链进 root（`/etc/passwd`、`/etc/group` 得手工补，
它们是 activation 时生成的，store 里没有）：

```sh
SYS=$(nix build --no-link --print-out-paths .#nixosConfigurations.sandbox.config.system.build.toplevel)
ROOT=/tmp/sbroot
mkdir -p $ROOT/{usr/bin,var/lib,run,tmp,root,proc,sys,dev,etc,var/empty}
chmod 1777 $ROOT/tmp
for f in $SYS/etc/*; do ln -sfn "$f" $ROOT/etc/$(basename "$f"); done
printf 'root:x:0:0:root:/root:/run/current-system/sw/bin/bash\n' > $ROOT/etc/passwd
printf 'root:x:0:\nusers:x:100:\n' > $ROOT/etc/group

sudo systemd-nspawn -D $ROOT -M sbtest \
  --bind-ro=/nix/store --bind=$SYS:/run/current-system --bind-ro=/nix/var/nix/db \
  --private-network --register=no --keep-unit /run/current-system/init

# 进容器（--register=no 时 machinectl 看不到，用 nsenter）
INIT=$(pgrep -f '^/run/current-system/init' | head -1)
sudo nsenter -t $INIT -m -p -i -- systemctl is-active openlist
sudo nsenter -t $INIT -m -p -i -- curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5244/
```

## 备注

- `boot.enableContainers = true` 仍然建议开：`nixos-container` 本身能用（create/destroy 正常），
  只是**启动**这一步被上面的 init 变更卡住。等上游修了就能直接用 `nixos-container start`。
- 沙盒里的 `openlist` 用 `user = "root"; workDir = "/root";`，
  因为容器里没有普通用户。真机上按 README 改成你自己的用户。
