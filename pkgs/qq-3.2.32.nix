# QQ 3.2.32_260812（钉版）—— 专门给 SnowLuma 的 native hook 用
# SnowLuma 的 hook 是与 QQ 版本对齐的，官方镜像就钉这个版本
# （SnowLuma.Docker.Framework/Dockerfile：ARG QQ_VERSION=3.2.32_260812 / QQ_CHANNEL=3f89efc5）。
# 实测在 3.2.34 上：群聊通道正常，但「好友私聊上报」能力探测返回 status=-1，
# bot 因此收不到私聊消息；换回 3.2.32 后该能力才可用。
# 桌面自己用的 pkgs.qq（3.2.34，configuration.nix §7 的 overlay）不动，
# 这里只是多给 hook 一份对齐版本的 QQ。
{
  qq,
  fetchurl,
}:

qq.overrideAttrs (
  _old: rec {
    version = "3.2.32-2026-08-12";
    name = "qq-${version}";

    # 腾讯 CDN 的直链会失效（要用签名接口换临时链接），这里用社区镜像仓库的归档，
    # hash 取自 SnowLuma 官方 Dockerfile 里的 QQ_AMD64_SHA256
    src = fetchurl {
      url = "https://github.com/Rodert/qq-versions/releases/download/qq-packages-20260813-1d08f1d4/QQ_3.2.32_260812_amd64_01.deb";
      hash = "sha256-0IXdiTlyJQYeufGUMI9ogSmBjtRFd36XpKChbhPXsOg=";
    };
  }
)
