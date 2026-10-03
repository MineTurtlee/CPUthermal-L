#!/bin/sh
set -e
# 使用 RootHide 官方 Theos 原生方案，产物无需 RootHide Patcher 二次转换。
sed -i '' 's/, preferenceloader/, preferenceloader, roothide/g' control
sed -i '' 's/= substrate/= substrate roothide/g' Makefile

sed -i '' 's/# / /g' InsulationPrefs/Makefile

make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
