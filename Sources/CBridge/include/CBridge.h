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
/* Fixed local CUPS recovery client; request/response helpers are hardware-free. */
ipp_t *mb_recovery_jobs_request(const char *name,const char *user);
ipp_t *mb_recovery_cancel_request(const char *name,const char *user,const int *ids,size_t count);
int mb_recovery_job_ids(ipp_t *response,const char *name,const char *user,int *ids,size_t capacity);
int mb_cancel_pending_jobs(const char *name,const char *user);
int mb_recovery_watchdog(int parent_fd,double timeout_seconds);
int mb_lpadmin_authorized(char *const *arguments);
