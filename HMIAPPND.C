/* HMIAPPND.C
   Append new driver to the end of a HMI driver blob
   Written in C since this is really the only sane way to get something running
   on both Unix and DOS, at least at the moment...
   */

#include <stdio.h>
#include <string.h>
#include <stdint.h>

#ifdef __unix__
/* TODO: Find a better define for this?? */
#define stricmp strcasecmp
#define strnicmp strncasecmp
#include <strings.h>
#endif

#define INFILEARG "oldfile="
#define DRVFILEARG "drvfile="
#define OUTFILEARG "newfile="
#define DEVIDARG "devid="
#define FLASHTECKARG "--flashteck"

#define MINDEVID 0xE000
#define MAXDEVID 0xE200

#define EXT_FLASHTECK 0x4000
#define EXT_RATIONAL  0x8000

#define COPYBUF_SIZE 0x100 /* One page */

int main(int argc, char **argv, const char **envp) {
	char *infile = NULL;
	char *drvfile = NULL;
	char *outfile = NULL;

	uint32_t wDeviceID = 0;
	uint32_t wExtenderType = EXT_RATIONAL;

	/* Declarations for later... */
	char szName[32], copy_buffer[COPYBUF_SIZE];
	long copy_filesize;
	uint32_t hdrstart, wDrivers, lNextDriver, wSize;
	FILE *inhdl, *outhdl, *drvhdl;

	int i = 0;	
	for(i = 0; i < argc; i++) {
		if(!strnicmp(argv[i], INFILEARG, strlen(INFILEARG))) {
			infile = argv[i] + strlen(INFILEARG);
		} else if(!strnicmp(argv[i], DRVFILEARG, strlen(DRVFILEARG))) {
			drvfile = argv[i] + strlen(DRVFILEARG);
		} else if(!strnicmp(argv[i], OUTFILEARG, strlen(OUTFILEARG))) {
			outfile = argv[i] + strlen(OUTFILEARG);
		} else if(!strnicmp(argv[i], DEVIDARG, strlen(DEVIDARG))) {
			sscanf(argv[i], DEVIDARG"%4x", &wDeviceID);
		} else if(!strnicmp(argv[i], FLASHTECKARG, strlen(FLASHTECKARG))) {
			wExtenderType = EXT_FLASHTECK;
		}
	}

	if(infile == NULL || drvfile == NULL || outfile == NULL ||
		wDeviceID < MINDEVID || wDeviceID > MAXDEVID ||
		!(wExtenderType == EXT_RATIONAL || wExtenderType == EXT_FLASHTECK)) {
		printf("Usage:\t%s [%s]"
			" \\\n\t%s<Input HMIDRV.386 file>"
			" \\\n\t%s<Output HMIDRV.386 file>"
			" \\\n\t%s<File to append>"
			" \\\n\t%s<Device ID>"
			"\nDevice ID and Extender Type must be specified in hex"
			"\nValid Device IDs are from %4X to %4X"
			"\nWithout the \"FLASHTECK\" option, the driver is assumed to be for \"RATIONAL\"-type DOS Extenders\n",
			argv[0], FLASHTECKARG,
			INFILEARG, OUTFILEARG, DRVFILEARG, DEVIDARG,
			MINDEVID, MAXDEVID);
		return 1;
	}

	inhdl = fopen(infile, "rb");
	if(!inhdl) {
		perror("Coudn't open input file");
		return -1;
	}

	outhdl = fopen(outfile, "wb");
	if(!outhdl) {
		perror("Coudn't open output file");
		return -1;
	}

	drvhdl = fopen(drvfile, "rb");
	if(!drvhdl) {
		perror("Coudn't open driver file");
		return -1;
	}

	/* Copy over the "szName" field of the file header */
	fread(szName, sizeof(char), 32, inhdl);
	fwrite(szName, sizeof(char), 32, outhdl);

	/* Number of drivers in the file */
	fread(&wDrivers, sizeof(uint32_t), 1, inhdl);
	wDrivers++; /* We're appending one! */
	fwrite(&wDrivers, sizeof(uint32_t), 1, outhdl);

	printf("szName and wDrivers written...\n");

	/* Figure out how much stuff to copy to the new file */
	fseek(inhdl, 0, SEEK_END);
	copy_filesize = ftell(inhdl);
	fseek(inhdl, ftell(outhdl), SEEK_SET); /* Back to where we were... */

	/* Copy it */
	while(ftell(inhdl) < copy_filesize) {
		fwrite(copy_buffer, sizeof(char),
			fread(copy_buffer, sizeof(char), COPYBUF_SIZE, inhdl),
			outhdl);
	}
	printf("Old HMIDRV file copied to new one\n");

	/* Construct the new driver header */
	/* Where is the current header starting? */
	hdrstart = ftell(outhdl);
	/* Size of the new driver */
	fseek(drvhdl, 0, SEEK_END);
	wSize = ftell(drvhdl);
	fseek(drvhdl, 0, SEEK_SET);
	/* End of the driver in the file (header size is 32 + 4*4 = 48 bytes) */
	lNextDriver = hdrstart + wSize + 48;

	memset(szName, 0, 32); /* Make sure it's null-padded */
	strncpy(szName, drvfile, 32);
	fwrite(szName, sizeof(char), 32, outhdl);
	fwrite(&lNextDriver, sizeof(uint32_t), 1, outhdl);
	fwrite(&wSize, sizeof(uint32_t), 1, outhdl);
	fwrite(&wDeviceID, sizeof(uint32_t), 1, outhdl);
	fwrite(&wExtenderType, sizeof(uint32_t), 1, outhdl);
	printf("New driver header written\n");

	/* Copy it */
	while(ftell(drvhdl) < wSize) {
		fwrite(copy_buffer, sizeof(char),
			fread(copy_buffer, sizeof(char), COPYBUF_SIZE, drvhdl),
			outhdl);
	}
	printf("All done!\n");

	return 0;
}

