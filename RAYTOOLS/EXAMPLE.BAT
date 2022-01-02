@echo off
rem This is an example batch file for getting HD Audio working on Rayman Junior
rem UK Volume 1 (EDUGB1).
rem Assumptions:
rem * The CD is in drive D:
rem * The game is installed in C:\EDUGB1
rem * HMID*.386 in C:\EDUGB1 have already been patched (DOSBUILD.BAT does this)

rem You should also set the env variables like HDA_BUS, HDA_WIDGET, etc.

soundbin d:\data\sound.bin c:\edugb1\sound.bin
hmiredir c:\edugb1 sound.bin
d:
cd d:\
install
