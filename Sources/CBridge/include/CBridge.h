#pragma once
#include <cups/raster.h>
#include <stdint.h>
#include <sys/types.h>
typedef struct MBReader MBReader;
MBReader *mb_raster_open(int fd, uint64_t max_bytes, double timeout_seconds);
int mb_raster_header(MBReader *, cups_page_header2_t *);
unsigned mb_raster_pixels(MBReader *, unsigned char *, unsigned);
void mb_raster_close(MBReader *);
#include <cups/cups.h>
int mb_queue_snapshot(const char *name,char *location,size_t location_size,char *uri,size_t uri_size);
const char *mb_cups_host(void);
int mb_queue_status(ipp_status_t status,int response_received);
int mb_lpadmin_authorized(char *const *arguments);
