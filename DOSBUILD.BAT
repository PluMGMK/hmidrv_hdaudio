@echo off

jwasmd -bin drvsrc\hda16s.asm
if errorlevel 1 goto end

rem Device ID
echo &HE040 > basinput.tmp
rem Extender Type (Rational)
echo &H8000 >> basinput.tmp
rem File to append (the one we just assembled)
echo HDA16S.BIN	>> basinput.tmp

rem File to append to (change as necessary for your system
echo C:\RAYMAN\HMIDRV.OLD >> basinput.tmp
rem Dest file (change as necessary for your system
echo C:\RAYMAN\HMIDRV.386 >> basinput.tmp

type basinput.tmp | qbasic /run hmiappnd.bas 
del basinput.tmp

:end
