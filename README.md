# HMIDRV_HDAudio
This is a driver for [Intel High Definition Audio](https://en.wikipedia.org/wiki/Intel_High_Definition_Audio) controllers, for use with Human Machine Interface's (HMI)'s Sound Operating System **version 3**, perhaps better known as `HMIDRV.386`.
The project was inspired by [Japheth's `HDAUtils`](https://github.com/Baron-von-Riedesel/HDAutils), and the idea is to give old DOS programs / games (such as Rayman) the ability to play sound through modern hardware.
So far, it has been tested with the aforementioned Rayman, on MS-DOS 6.2 running on a PC from 2014 with [this motherboard](https://us.msi.com/Motherboard/Z97-GAMING-3).

## Limitations
* Only supports version 3 of the Sound Operating System, used in Rayman. Version 4 is not supported.
* Only supports clients using `RATIONAL`-type DOS extenders, not `FLASHTECK`.
* Currently only supports 16-bit stereo playback

## `TODO` list
* Figure out cause of skipping in looping sounds, and eliminate it
* Write a detector (for `HMIDET.386`) to complement the driver
* Expand the build/installation process so it can be run from modern operating systems and/or DOS without QBASIC installed
* Add some kind of MSCDEX hook to play CD Audio through the same driver, since modern computers tend not to have analogue music players (with direct connections to the sound card) built into optical drives anymore
* [MAYBE] make 8-bit and mono versions
