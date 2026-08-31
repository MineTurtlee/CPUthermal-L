#!/bin/sh
set -e
# 使用 RootHide 官方 Theos 原生方案，产物无需 RootHide Patcher 二次转换。
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
