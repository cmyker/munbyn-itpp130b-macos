#include "CBridge.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <poll.h>
#include <errno.h>
#include <time.h>
#include <pthread.h>
#include <sys/stat.h>

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
struct recovery_lifetime { int fd; double deadline; };
static void *watch_recovery_parent(void *opaque) {
    struct recovery_lifetime *lifetime = opaque;
    for (;;) {
        double left = lifetime->deadline - now_seconds();
        if (left <= 0) _exit(75);
        struct pollfd event = {lifetime->fd,POLLIN,0};
        int ready = poll(&event,1,(int)(left * 1000) + 1);
        if (ready < 0 && errno == EINTR) continue;
        // No data belongs on this channel. EOF, unexpected data, errors and the
        // child-local deadline kill the entire helper, including blocked RPCs.
        if (ready != 0) _exit(75);
    }
}
int mb_recovery_watchdog(int parent_fd,double timeout_seconds) {
    struct stat info;
    if (parent_fd < 0 || timeout_seconds <= 0 || timeout_seconds > 30 ||
        fstat(parent_fd,&info) || !S_ISFIFO(info.st_mode)) return -1;
    struct pollfd event = {parent_fd,POLLIN,0};
    if (poll(&event,1,0) != 0) return -1;
    struct recovery_lifetime *lifetime = malloc(sizeof(*lifetime));
    if (!lifetime) return -1;
    lifetime->fd = parent_fd; lifetime->deadline = now_seconds() + timeout_seconds;
    pthread_t thread;
    if (pthread_create(&thread,NULL,watch_recovery_parent,lifetime)) { free(lifetime); return -1; }
    pthread_detach(thread); return 0;
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
static int valid_queue(const char *name) {
    return name && *name && strlen(name) <= 128 &&
        strspn(name,"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_") == strlen(name);
}
static int valid_user(const char *user) { return user && *user && strlen(user) <= 256; }
ipp_t *mb_recovery_jobs_request(const char *name,const char *user) {
    if (!valid_queue(name) || !valid_user(user)) return NULL;
    char uri[320]; snprintf(uri,sizeof(uri),"ipp://localhost:631/printers/%s",name);
    ipp_t *request = ippNewRequest(IPP_OP_GET_JOBS);
    if (!request) return NULL;
    const char *attributes[] = {"job-id","job-originating-user-name","job-printer-uri"};
    if (!ippAddString(request,IPP_TAG_OPERATION,IPP_TAG_URI,"printer-uri",NULL,uri) ||
        !ippAddString(request,IPP_TAG_OPERATION,IPP_TAG_NAME,"requesting-user-name",NULL,user) ||
        !ippAddBoolean(request,IPP_TAG_OPERATION,"my-jobs",1) ||
        !ippAddString(request,IPP_TAG_OPERATION,IPP_TAG_KEYWORD,"which-jobs",NULL,"not-completed") ||
        !ippAddInteger(request,IPP_TAG_OPERATION,IPP_TAG_INTEGER,"limit",1025) ||
        !ippAddStrings(request,IPP_TAG_OPERATION,IPP_TAG_KEYWORD,"requested-attributes",3,NULL,attributes)) {
        ippDelete(request); return NULL;
    }
    return request;
}
ipp_t *mb_recovery_cancel_request(const char *name,const char *user,const int *ids,size_t count) {
    if (!valid_queue(name) || !valid_user(user) || !ids || count == 0 || count > 1024) return NULL;
    for (size_t i = 0; i < count; i++) if (ids[i] <= 0) return NULL;
    char uri[320]; snprintf(uri,sizeof(uri),"ipp://localhost:631/printers/%s",name);
    ipp_t *request = ippNewRequest(IPP_OP_CANCEL_MY_JOBS);
    if (!request) return NULL;
    // A missing ID list means bulk cancellation, so fail the entire builder if
    // any required attribute cannot be added. The scheduler checks destination
    // and owner for ALL IDs before mutating, including jobs moved since query.
    if (!ippAddString(request,IPP_TAG_OPERATION,IPP_TAG_URI,"printer-uri",NULL,uri) ||
        !ippAddString(request,IPP_TAG_OPERATION,IPP_TAG_NAME,"requesting-user-name",NULL,user) ||
        !ippAddIntegers(request,IPP_TAG_OPERATION,IPP_TAG_INTEGER,"job-ids",(int)count,ids)) {
        ippDelete(request); return NULL;
    }
    return request;
}
static int append_matching_job(int id,const char *owner,const char *uri,const char *name,
                               const char *user,int *ids,size_t capacity,size_t *count) {
    if (id <= 0 || !owner || !uri) return -1;
    char scheme[32],username[256],host[256],resource[512],expected[256]; int port;
    if (httpSeparateURI(HTTP_URI_CODING_ALL,uri,scheme,sizeof(scheme),username,sizeof(username),
                        host,sizeof(host),&port,resource,sizeof(resource)) < HTTP_URI_STATUS_OK) return -1;
    snprintf(expected,sizeof(expected),"/printers/%s",name);
    if (!strcasecmp(resource,expected) && !strcasecmp(owner,user)) {
        if (*count >= capacity) return -1;
        ids[(*count)++] = id;
    }
    return 0;
}
int mb_recovery_job_ids(ipp_t *response,const char *name,const char *user,int *ids,size_t capacity) {
    if (!response || !valid_queue(name) || !valid_user(user) || !ids || capacity > 1024 ||
        ippGetStatusCode(response) >= IPP_STATUS_ERROR_BAD_REQUEST) return -1;
    int in_job = 0,id = 0; size_t count = 0,groups = 0;
    const char *owner = NULL,*uri = NULL;
    for (ipp_attribute_t *a = ippFirstAttribute(response); a; a = ippNextAttribute(response)) {
        if (ippGetGroupTag(a) != IPP_TAG_JOB) {
            if (in_job && append_matching_job(id,owner,uri,name,user,ids,capacity,&count)) return -1;
            in_job = 0; id = 0; owner = uri = NULL; continue;
        }
        if (!in_job && ++groups > 1024) return -1;
        in_job = 1;
        const char *key = ippGetName(a); if (!key) return -1;
        if (!strcmp(key,"job-id")) {
            if (id || ippGetValueTag(a) != IPP_TAG_INTEGER || ippGetCount(a) != 1) return -1;
            id = ippGetInteger(a,0);
        } else if (!strcmp(key,"job-originating-user-name")) {
            if (owner || ippGetValueTag(a) != IPP_TAG_NAME || ippGetCount(a) != 1) return -1;
            owner = ippGetString(a,0,NULL);
        } else if (!strcmp(key,"job-printer-uri")) {
            if (uri || ippGetValueTag(a) != IPP_TAG_URI || ippGetCount(a) != 1) return -1;
            uri = ippGetString(a,0,NULL);
        }
    }
    if (in_job && append_matching_job(id,owner,uri,name,user,ids,capacity,&count)) return -1;
    return (int)count;
}
static ipp_t *recovery_request(http_t *http,ipp_t *request,double deadline) {
    double remaining = deadline - now_seconds();
    if (!request || remaining <= 0) { if (request) ippDelete(request); return NULL; }
    httpSetTimeout(http,remaining < 5 ? remaining : 5,NULL,NULL);
    return cupsDoRequest(http,request,"/jobs/");
}
static const char *no_recovery_password(const char *prompt,http_t *http,const char *method,const char *resource,void *context) {
    (void)prompt; (void)http; (void)method; (void)resource; (void)context;
    return NULL;
}
int mb_cancel_pending_jobs(const char *name,const char *user) {
    if (!valid_queue(name) || !valid_user(user)) return -1;
    // This helper runs in a dedicated child; never wait for a terminal password.
    cupsSetPasswordCB2(no_recovery_password,NULL);
    double deadline = now_seconds() + 15;
    http_t *http = httpConnect2(mb_cups_host(),631,NULL,AF_UNSPEC,HTTP_ENCRYPTION_IF_REQUESTED,1,3000,NULL);
    if (!http) return -1;
    int ids[1024],result = -1;
    ipp_t *response = recovery_request(http,mb_recovery_jobs_request(name,user),deadline);
    int count = mb_recovery_job_ids(response,name,user,ids,1024);
    if (response) ippDelete(response);
    if (count < 0) goto done;
    // No mutation for an empty queue. A standard account may need Print Center
    // if the scheduler denies this operation; never fall back to global IDs.
    if (count > 0) {
        response = recovery_request(http,mb_recovery_cancel_request(name,user,ids,(size_t)count),deadline);
        if (!response) goto done;
        ipp_status_t status = ippGetStatusCode(response); ippDelete(response);
        if (status == IPP_STATUS_ERROR_NOT_AUTHORIZED || status == IPP_STATUS_ERROR_FORBIDDEN ||
            status == IPP_STATUS_ERROR_NOT_AUTHENTICATED) { result = -3; goto done; }
        if (status >= IPP_STATUS_ERROR_BAD_REQUEST && status != IPP_STATUS_ERROR_NOT_FOUND) goto done;
    }
    response = recovery_request(http,mb_recovery_jobs_request(name,user),deadline);
    count = mb_recovery_job_ids(response,name,user,ids,1024);
    if (response) ippDelete(response);
    result = count == 0 ? 0 : count > 0 ? -2 : -1;
done:
    httpClose(http); return result;
}
int mb_queue_status(ipp_status_t status,int response_received) {
    if (status == IPP_STATUS_ERROR_NOT_FOUND) return 0;
    return response_received && status < IPP_STATUS_ERROR_BAD_REQUEST ? 1 : -1;
}
int mb_queue_snapshot(const char *name,char *location,size_t location_size,char *uri,size_t uri_size) {
    if (!name || !*name || strlen(name) > 128 || strspn(name,"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_") != strlen(name)) return -1;
    http_t *http = httpConnect2(mb_cups_host(),631,NULL,AF_UNSPEC,HTTP_ENCRYPTION_IF_REQUESTED,1,5000,NULL);
    if (!http) return -1;
    httpSetTimeout(http,5.0,NULL,NULL);
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
