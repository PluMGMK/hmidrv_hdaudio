@echo off
rem This is an example batch file for getting HD Audio working on Rayman Junior
rem UK Volume 1 (EDUGB3).
rem Assumptions:
rem * The CD is in drive D:
rem * The game is installed in C:\EDUGB3
rem * HMID*.386 in C:\EDUGB3 have already been patched

rem You should also set the env variables like HDA_BUS, HDA_WIDGET, etc.

soundbin d:\data\sound.bin c:\edugb3\sound.bin
hmiredir c:\edugb3 sound.bin
d:
cd d:\
install
