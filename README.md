# HMIDRV_HDAudio
This is a driver for [Intel High Definition Audio](https://en.wikipedia.org/wiki/Intel_High_Definition_Audio) controllers, for use with Human Machine Interface's (HMI)'s Sound Operating System **version 3**, perhaps better known as `HMIDRV.386`.
The project was inspired by [Japheth's `HDAUtils`](https://github.com/Baron-von-Riedesel/HDAutils), and the idea is to give old DOS programs / games (such as Rayman) the ability to play sound through modern hardware.
So far, it has been tested with the aforementioned Rayman, on MS-DOS 6.2 running on a PC from 2014 with [this motherboard](https://us.msi.com/Motherboard/Z97-GAMING-3) (to clarify, I'm booting DOS *natively* on the system, not with QEMU or the like).

Experimental support is also included for mixing CD Audio into the stream, by hooking MSCDEX, since modern computers tend not to have analogue music players (with direct connections to the sound card) built into optical drives anymore.

## Limitations
* Only supports version 3 of the Sound Operating System, used in Rayman. Version 4 is not supported.
* Only supports clients using `RATIONAL`-type (i.e. DOS/4GW-like) DOS extenders, not `FLASHTECK` (Phar Lap like).
* Currently only supports 16-bit stereo playback
* CD Audio requires your drive to support raw reading (and support is currently incomplete - see below)

## `TODO` list
* Figure out cause of skipping in looping sounds, and eliminate it
* Likewise figure out and eliminate cause of CD Audio crackling
* Write a detector (for `HMIDET.386`) to complement the driver
* Implement support for volume control of CD Audio even when the drive doesn't have built-in audio capability
* Implement support for four-channel CDs (playing two channels, which can be selected by running applications)
* [MAYBE] implement support for pre-emphasis in CD Audio
* [MAYBE] make 8-bit and mono versions
