#include "CBridge.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <poll.h>
#include <errno.h>
#include <time.h>

struct MBReader {
    int fd, eof, failed;
    uint64_t bytes, limit;
    double deadline;
    unsigned char prefix[4];
    size_t prefix_pos;
    cups_raster_t *raster;
};
static double now_seconds(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC,&ts);
    return ts.tv_sec + ts.tv_nsec / 1000000000.0;
}
static ssize_t bounded_read(MBReader *ctx,unsigned char *dst,size_t count) {
    if (ctx->failed) return -1;
    size_t got = 0;
    while (got < count) {
        double left = ctx->deadline - now_seconds();
        if (left <= 0 || ctx->bytes >= ctx->limit) { ctx->failed = 1; return -1; }
        struct pollfd p = {ctx->fd,POLLIN,0};
        int result = poll(&p,1,(int)(left * 1000));
        if (result < 0 && errno == EINTR) continue;
        if (result <= 0) { ctx->failed = 1; return -1; }
        size_t amount = count - got;
        if (amount > ctx->limit - ctx->bytes) amount = (size_t)(ctx->limit - ctx->bytes);
        ssize_t n = read(ctx->fd,dst + got,amount);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) { ctx->failed = 1; return -1; }
        if (n == 0) { ctx->eof = 1; break; }
        got += (size_t)n; ctx->bytes += (uint64_t)n;
    }
    return (ssize_t)got;
}
static ssize_t raster_io(void *opaque,unsigned char *dst,size_t count) {
    MBReader *ctx = opaque;
    size_t replay = 4 - ctx->prefix_pos;
    if (replay > count) replay = count;
    if (replay) { memcpy(dst,ctx->prefix + ctx->prefix_pos,replay); ctx->prefix_pos += replay; }
    if (replay == count) return (ssize_t)count;
    ssize_t n = bounded_read(ctx,dst + replay,count - replay);
    return n < 0 ? -1 : (ssize_t)replay + n;
}
MBReader *mb_raster_open(int fd,uint64_t max_bytes,double timeout_seconds) {
    if (timeout_seconds <= 0 || timeout_seconds > 300 || max_bytes < 4) return NULL;
    MBReader *ctx = calloc(1,sizeof(*ctx)); if (!ctx) return NULL;
    ctx->fd = fd; ctx->limit = max_bytes; ctx->deadline = now_seconds() + timeout_seconds;
    if (bounded_read(ctx,ctx->prefix,4) != 4 ||
        (memcmp(ctx->prefix,"3SaR",4) && memcmp(ctx->prefix,"RaS3",4))) { free(ctx); return NULL; }
    /* Deliberately reject compressed/v1/PWG/Apple variants before libcups allocates
       compression buffers from an untrusted header. No handwritten raster parser. */
    ctx->raster = cupsRasterOpenIO(raster_io,ctx,CUPS_RASTER_READ);
    if (!ctx->raster) { free(ctx); return NULL; }
    return ctx;
}
int mb_raster_header(MBReader *ctx,cups_page_header2_t *header) {
    uint64_t before = ctx->bytes;
    if (cupsRasterReadHeader2(ctx->raster,header)) return 1;
    return !ctx->failed && ctx->eof && ctx->bytes == before ? 0 : -1;
}
unsigned mb_raster_pixels(MBReader *ctx,unsigned char *dst,unsigned length) {
    return cupsRasterReadPixels(ctx->raster,dst,length);
}
void mb_raster_close(MBReader *ctx) {
    if (ctx) { cupsRasterClose(ctx->raster); free(ctx); }
}
const char *mb_cups_host(void) { return "localhost"; }
int mb_queue_status(ipp_status_t status,int response_received) {
    if (status == IPP_STATUS_ERROR_NOT_FOUND) return 0;
    return response_received && status < IPP_STATUS_ERROR_BAD_REQUEST ? 1 : -1;
}
int mb_queue_snapshot(const char *name,char *location,size_t location_size,char *uri,size_t uri_size) {
    if (!name || !*name || strlen(name) > 128 || strspn(name,"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_") != strlen(name)) return -1;
    http_t *http = httpConnect2(mb_cups_host(),631,NULL,AF_UNSPEC,HTTP_ENCRYPTION_IF_REQUESTED,1,5000,NULL);
    if (!http) return -1;
    char resource[256],printer_uri[320];
    snprintf(resource,sizeof(resource),"/printers/%s",name);
    snprintf(printer_uri,sizeof(printer_uri),"ipp://localhost:631%s",resource);
    ipp_t *request = ippNewRequest(IPP_OP_GET_PRINTER_ATTRIBUTES);
    ippAddString(request,IPP_TAG_OPERATION,IPP_TAG_URI,"printer-uri",NULL,printer_uri);
    const char *attributes[] = {"printer-location","device-uri"};
    ippAddStrings(request,IPP_TAG_OPERATION,IPP_TAG_KEYWORD,"requested-attributes",2,NULL,attributes);
    ipp_t *response = cupsDoRequest(http,request,resource);
    int result = mb_queue_status(response ? ippGetStatusCode(response) : cupsLastError(),response != NULL);
    httpClose(http);
    if (result != 1) { if (response) ippDelete(response); return result; }
    ipp_attribute_t *a_attr = ippFindAttribute(response,"printer-location",IPP_TAG_ZERO);
    ipp_attribute_t *b_attr = ippFindAttribute(response,"device-uri",IPP_TAG_URI);
    const char *a = a_attr ? ippGetString(a_attr,0,NULL) : NULL;
    const char *b = b_attr ? ippGetString(b_attr,0,NULL) : NULL;
    snprintf(location,location_size,"%s",a ? a : "");
    snprintf(uri,uri_size,"%s",b ? b : "");
    ippDelete(response); return 1;
}
#include <Security/Authorization.h>
#include <Security/AuthorizationTags.h>
int mb_lpadmin_authorized(char *const *arguments) {
    AuthorizationRef auth = NULL;
    OSStatus status = AuthorizationCreate(NULL,kAuthorizationEmptyEnvironment,kAuthorizationFlagDefaults,&auth);
    if (status != errAuthorizationSuccess) return (int)status;
    const char *tool = "/usr/sbin/lpadmin";
    AuthorizationItem item = {kAuthorizationRightExecute,strlen(tool),(void *)tool,0};
    AuthorizationRights rights = {1,&item};
    status = AuthorizationCopyRights(auth,&rights,kAuthorizationEmptyEnvironment,
        kAuthorizationFlagInteractionAllowed | kAuthorizationFlagExtendRights | kAuthorizationFlagPreAuthorize,NULL);
    if (status == errAuthorizationSuccess) {
        FILE *output = NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        status = AuthorizationExecuteWithPrivileges(auth,tool,kAuthorizationFlagDefaults,arguments,&output);
#pragma clang diagnostic pop
        if (output) { char buffer[1024]; while (fread(buffer,1,sizeof(buffer),output) > 0) {} fclose(output); }
    }
    AuthorizationFree(auth,kAuthorizationFlagDestroyRights); return (int)status;
}
