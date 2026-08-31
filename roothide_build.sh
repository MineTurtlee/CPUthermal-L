#!/bin/sh
set -e
# RootHide 使用 rootless-compat 安装此 rootless 包，避免维护另一套二进制路径。
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
