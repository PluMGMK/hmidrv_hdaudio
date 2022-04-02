@echo off
rem This is an example batch file for getting HD Audio working on Rayman
rem Designer (RAYKIT). Much more straightforward than EDU since the utility runs
rem from the hard disk!
rem Assumptions:
rem * The CD is in drive D:
rem * The game is installed in C:\RAYKIT
rem * HMID*.386 in C:\RAYKIT have already been patched (DOSBUILD.BAT does this)

rem You should also set the env variables like HDA_BUS, HDA_WIDGET, etc.

soundbin d:\kit\data\sound.bin c:\raykit\data\sound.bin
c:
cd c:\raykit
setsound
