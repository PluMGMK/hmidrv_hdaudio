@echo off

jwasmd -bin drvsrc\hda16s.asm
if errorlevel 1 goto end
rem Convention is to change last letter to 'w' for "RATIONAL" version
move hda16s.bin hdw16s.bin

jwasmd -bin -D?FLASHTEK=1 drvsrc\hda16s.asm
if errorlevel 1 goto end

hmiappnd.exe oldfile=C:\RAYMAN\HMIDRV.OLD newfile=C:\RAYMAN\HMIDRV.386 drvf:E040=hda16s.bin drvr:E040=hdw16s.bin

:end
