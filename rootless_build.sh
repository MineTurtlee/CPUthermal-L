#!/bin/sh
set -e
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
