@echo off

jwasmd -bin drvsrc\hda16s.asm
if errorlevel 1 goto end

hmiappnd oldfile=C:\RAYMAN\HMIDRV.OLD newfile=C:\RAYMAN\HMIDRV.386 drvfile=HDA16S.BIN devid=E040

:end
