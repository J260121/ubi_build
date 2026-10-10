#!/bin/bash
# Copy custom local packages into OpenWrt tree so they are available during build
if [ -d "$GITHUB_WORKSPACE/package/luci-compat-keep" ]; then
  mkdir -p package
  cp -r "$GITHUB_WORKSPACE/package/luci-compat-keep" package/
fi
echo 'src-git passwall https://github.com/xiaorouji/openwrt-passwall' >>feeds.conf.default
