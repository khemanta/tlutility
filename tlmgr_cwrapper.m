/*
 *  tlmgr_cwrapper.c
 *  TeX Live Manager
 *
 *  Created by Adam Maxwell on 12/7/08.
 *
 This software is Copyright (c) 2008-2010
 Adam Maxwell. All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions
 are met:
 
 - Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 
 - Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in
 the documentation and/or other materials provided with the
 distribution.
 
 - Neither the name of Adam Maxwell nor the names of any
 contributors may be used to endorse or promote products derived
 from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <pwd.h>
#include <string.h>
#include <sys/time.h>
#include <sys/stat.h>
#include <sys/event.h>

#import <Foundation/Foundation.h>
#import "TLMLogMessage.h"
#include <asl.h>

#define SENDER_NAME @"tlmgr_cwrapper"

@protocol TLMAuthOperationProtocol

- (void)setWrapperPID:(in pid_t)pid;
- (void)setUnderlyingPID:(in pid_t)pid;

@end

extern char **environ;

static id _logServer = nil;
static TLMLogMessageFlags _messageFlags = TLMLogDefault;

static void establish_log_connection()
{
    @try {
        _logServer = [[NSConnection rootProxyForConnectionWithRegisteredName:SERVER_NAME host:nil] retain];
        [_logServer setProtocolForProxy:@protocol(TLMLogServerProtocol)];
    }
    @catch (id exception) {
        asl_log(NULL, NULL, ASL_LEVEL_ERR, "tlmgr_cwrapper: caught exception %s connecting to server", [[exception description] UTF8String]);
        _logServer = nil;
    }
}    

static void log_message_with_level(const char *level, NSString *message, NSUInteger flags)
{
    if (nil == _logServer) establish_log_connection();
    
    // !!! early return; if still not available, log to asl and bail out
    if (nil == _logServer) {
        static bool didWarn = false;
        if (false == didWarn)
            asl_log(NULL, NULL, ASL_LEVEL_ERR, "log_message_with_level: server is nil");
        didWarn = true;
        asl_log(NULL, NULL, ASL_LEVEL_ERR, "%s", [message UTF8String]);
        return;
    }
    
    TLMLogMessage *msg = [TLMLogMessage new];
    [msg setDate:[NSDate date]];
    [msg setMessage:message];
    [msg setSender:SENDER_NAME];
    [msg setLevel:[NSString stringWithUTF8String:level]];
    [msg setPid:getpid()];
    [msg setFlags:flags];
    
    @try {
        [_logServer logMessage:msg];
    }
    @catch (id exception) {
        asl_log(NULL, NULL, ASL_LEVEL_ERR, "tlmgr_cwrapper: caught exception %s in log_message_with_level", [[exception description] UTF8String]);
        // log to asl as a fallback
        asl_log(NULL, NULL, ASL_LEVEL_ERR, "%s", [message UTF8String]);
        [_logServer release];
        _logServer = nil;
    }
    [msg release];    
}

static void log_notice(NSString *format, ...)
{
    va_list list;
    va_start(list, format);
    NSMutableString *message = [[NSMutableString alloc] initWithFormat:format arguments:list];
    va_end(list);
    // fgets preserves newlines, so trim them here instead of messing with the C-string buffer
    CFStringTrimWhitespace((CFMutableStringRef)message);
    log_message_with_level(ASL_STRING_NOTICE, message, _messageFlags);
    [message release];
}

static void log_error(NSString *format, ...)
{
    va_list list;
    va_start(list, format);
    NSMutableString *message = [[NSMutableString alloc] initWithFormat:format arguments:list];
    va_end(list);
    // fgets preserves newlines, so trim them here instead of messing with the C-string buffer
    CFStringTrimWhitespace((CFMutableStringRef)message);
    log_message_with_level(ASL_STRING_ERR, message, TLMLogDefault);
    [message release];
}

static void log_lines_and_clear(NSMutableData *data, bool is_error)
{
    NSUInteger i, last = 0;
    const char *ptr = [data bytes];
    for (i = 0; i < [data length]; i++) {
     
        char ch = ptr[i];
        if (ch == '\n') {
            NSString *str = [[NSString alloc] initWithBytes:&ptr[last] length:(i - last) encoding:NSUTF8StringEncoding];
            // tlmgr 2008 and 2009 pretest have issues with perl and encoding, so here's a fallback
            if (nil == str && (i - last) > 0)
                str = [[NSString alloc] initWithBytes:&ptr[last] length:(i - last) encoding:NSMacOSRomanStringEncoding];
            
            // create a single log message per line and post it to the server
            if (is_error)
                log_error(@"%@", str);
            else
                log_notice(@"%@", str);
            [str release];
            last = i + 1;
        }
        
    }
    
    // clear the mutable data
    [data replaceBytesInRange:NSMakeRange(0, last) withBytes:NULL length:0];
}

/* 
 argv[0]: tlmgr_cwrapper
 argv[1]: DO server name for IPC
 argv[2]: log message flags
 argv[3]: y or n
 argv[4]: tlmgr
 argv[n]: tlmgr arguments
 */

#define ARG_SELF        0
#define ARG_SERVER_NAME 1
#define ARG_LOG_FLAGS   2
#define ARG_SET_HOME    3
#define ARG_CMD         4
#define ARG_CMD_ARGS    5
    
int main(int argc, char *argv[]) {
    
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
        
    /* this call was the original purpose of the program */
    /* http://www.cocoabuilder.com/archive/message/cocoa/2001/6/15/21704 */
    setuid(geteuid());
    
    if (argc < ARG_CMD_ARGS) {
        log_error(@"insufficient arguments");
        exit(1);
    }
        
    /* single integer, holding flags for the log messages       */
    /* NB: machine-readable output is all on stdout, not stderr */
    char *invalid = NULL;
    _messageFlags = strtoul(argv[ARG_LOG_FLAGS], &invalid, 10);
    if (invalid && '\0' != *invalid) {
        log_error(@"second argument '%s' was not an unsigned long value", argv[ARG_LOG_FLAGS]);
        exit(1);
    }
        
    /* Require a single character argument 'y' || 'n'.      */
    /* Don't accept 'yes' or 'no' or 'nitwit' as arguments. */
    char *c = argv[ARG_SET_HOME];
    if (strlen(c) != 1 || ('y' != *c && 'n' != *c)) {
        log_error(@"third argument '%s' was not recognized", c);
        exit(1);
    }
    
    /* If yes, do what sudo -H does: read root's passwd entry and change HOME. */
    if ('y' == *c) {    
                
        /* note that getuid() may no longer return 0 */
        struct passwd *pw = getpwuid(0);
        if (NULL == pw) {
            log_error(@"getpwuid failed in tlmgr_cwrapper");
            exit(1);
        }
        
        /* The point of this is to write to root's home directory, so make we are root */
        if (setuid(0) != 0) {
            log_error(@"UID %d cannot write to %s\n", getuid(), pw->pw_dir);
            exit(1);
        }
        
        setenv("HOME", pw->pw_dir, 1);
    }
    
    /* copy this for later logging */
    const char *childHome = strdup(getenv("HOME"));
        
    /* This is a security issue, since we don't want to trust relative paths. */
    if (strlen(argv[ARG_CMD]) == 0 || argv[ARG_CMD][0] != '/') {
        log_error(@"*** ERROR *** rejecting insecure path %s", argv[ARG_CMD]);
        exit(1);
    }
    
    /* This catches a stupid mistake that I've made a few times in configuring the task. */
    if (access(argv[ARG_CMD], X_OK) != 0) {
        log_error(@"*** ERROR *** non-executable file at path %s", argv[ARG_CMD]);
        exit(1);
    }
    
    /* Need this after fork(), so fail if we can't get it */
    struct passwd *nobody = getpwnam("nobody");
    if (NULL == nobody) {
        log_error(@"getpwnam failed in tlmgr_cwrapper");
        exit(1);
    }
    
    int i;
#if 0
    fprintf(stderr, "uid = %d, euid = %d\n", getuid(), geteuid());
    for (i = 0; i < argc; i++) {
        fprintf(stderr, "argv[%d] = %s\n", i, argv[i]);
    }
#endif
    
    /* ignore SIGPIPE */
    signal(SIGPIPE, SIG_IGN);

    int outpipe[2];
    int errpipe[2];
    
    /* pipe to avoid a race between exec and kevent; problem in BDSKTask isn't relevant here */
    int waitpipe[2];

    if (pipe(outpipe) < 0 || pipe(errpipe) < 0 || pipe(waitpipe) < 0) {
        log_error(@"pipe failed in tlmgr_cwrapper");
        exit(1);
    }
    
    if (dup2(outpipe[1], STDOUT_FILENO) < 0) {
        log_error(@"dup2 stdout failed in tlmgr_cwrapper");
        exit(1);
    }
    
    if (dup2(errpipe[1], STDERR_FILENO) < 0) {
        log_error(@"dup2 stderr failed in tlmgr_cwrapper");
        exit(1);
    }
    
    int ret = 0;
    pid_t child = fork();
    if (0 == child) {
        
        /* set process group for killpg() */
        (void)setpgid(getpid(), getpid());
        
        close(outpipe[0]);
        close(errpipe[0]);
        
        close(waitpipe[1]);
        char ignored;
        /* block until the parent has setup complete */
        read(waitpipe[0], &ignored, 1);    
        close(waitpipe[0]);

        i = execve(argv[ARG_CMD], &argv[ARG_CMD], environ);
        _exit(i);
    }
    else if (-1 == child) {
        perror("fork failed");
        exit(1);
    }
    else {
        
        /* drop privileges to nobody immediately after fork() (mainly for running as root) */            
        (void) setenv("HOME", nobody->pw_dir, 1);
        (void) setgid(nobody->pw_gid);
        (void) setuid(nobody->pw_uid);
        
        /* if dropping privileges failed, this call will succeed */
        if (setuid(0) == 0) {
            log_error(@"dropping privileges failed\n");
            exit(1);
        }
        else {
            log_error(@"dropped privileges to user nobody\n");
        }
        
        /*
         Formerly set this up immediately (before fork()) so the parent kqueue could monitor tlmgr_cwrapper,
         but waiting to use Foundation until after we drop privileges seems to be worthwhile.  In addition,
         the primary errors to catch prior to fork() are early-exit errors due to programming errors.
         */
        NSString *parentName = [NSString stringWithUTF8String:argv[ARG_SERVER_NAME]];
        id parent = [NSConnection rootProxyForConnectionWithRegisteredName:parentName host:nil];
        [parent setProtocolForProxy:@protocol(TLMAuthOperationProtocol)];
        
        /* allows the parent kqueue to monitor tlmgr_cwrapper and/or kill it */
        @try {
            [parent setWrapperPID:getpid()];
        }
        @catch (id exception) {
            log_error(@"failed to send PID to server:\n\t%@", exception);
        }        
        
        /* allows the parent kqueue to monitor tlmgr and/or kill it */
        @try {
            [parent setUnderlyingPID:child];
        }
        @catch (id exception) {
            log_error(@"failed to send PID to server:\n\t%@", exception);
        }
        
        /* log information as error so we get the TLMLogDefault flags */
        log_error(@"tlmgr_cwrapper: child HOME = '%s'\n", childHome);
        log_error(@"tlmgr_cwrapper: current HOME = '%s'\n", getenv("HOME"));
                        
        int kq_fd = kqueue();
#define TLM_EVENT_COUNT 3
        struct kevent events[TLM_EVENT_COUNT];
        memset(events, 0, sizeof(struct kevent) * TLM_EVENT_COUNT);
        
        close(outpipe[1]);
        close(errpipe[1]);
        
        EV_SET(&events[0], child, EVFILT_PROC, EV_ADD, NOTE_EXIT, 0, NULL);
        EV_SET(&events[1], outpipe[0], EVFILT_READ, EV_ADD, 0, 0, NULL);
        EV_SET(&events[2], errpipe[0], EVFILT_READ, EV_ADD, 0, 0, NULL);
        kevent(kq_fd, events, TLM_EVENT_COUNT, NULL, 0, NULL);
        
        /* kqueue setup complete, so widow the pipe to allow exec to proceed */
        close(waitpipe[1]);
        close(waitpipe[0]);
        
        struct timespec ts;
        ts.tv_sec = 0;
        ts.tv_nsec = 100000000;
        
        bool stillRunning = true;        
        struct kevent event;
        
        NSMutableData *errBuffer = [NSMutableData data];
        NSMutableData *outBuffer = [NSMutableData data];
        
        int eventCount;
        
        while ((eventCount = kevent(kq_fd, NULL, 0, &event, 1, &ts)) != -1 && stillRunning) {
            
            /* if this was a timeout, don't try reading from the event */
            if (0 == eventCount)
                continue;
            
            NSAutoreleasePool *innerPool = [NSAutoreleasePool new];
            
            if (event.filter == EVFILT_PROC && (event.fflags & NOTE_EXIT) == NOTE_EXIT) {
                
                stillRunning = false;
                log_error(@"child process pid = %d exited", child);
            }
            else if (event.filter == EVFILT_READ && event.ident == (unsigned)outpipe[0]) {
                
                size_t len = event.data;
                char sbuf[2048];
                char *buf = (len > sizeof(sbuf)) ? buf = malloc(len) : sbuf;
                len = read(event.ident, buf, len);
                [outBuffer appendBytes:buf length:len];
                if (buf != sbuf) free(buf);
                log_lines_and_clear(outBuffer, false);
            }
            else if (event.filter == EVFILT_READ && event.ident == (unsigned)errpipe[0]) {
                
                size_t len = event.data;
                char sbuf[2048];
                char *buf = (len > sizeof(sbuf)) ? buf = malloc(len) : sbuf;
                len = read(event.ident, buf, len);
                [errBuffer appendBytes:buf length:len];
                if (buf != sbuf) free(buf);
                log_lines_and_clear(errBuffer, true);
            }
            else {
                
                log_error(@"unhandled kevent with filter = %d", event.filter);
            }
            
            [innerPool release];
            
            /* originally checked here to see if tlmgr removed itself, but the dedicated update makes that unnecessary */
        }    
        
        /* log any leftovers */
        if ([outBuffer length]) {
            NSString *str = [[NSString alloc] initWithData:outBuffer encoding:NSUTF8StringEncoding];
            log_notice(@"%@", str);
            [str release];
        }
        
        if ([errBuffer length]) {
            NSString *str = [[NSString alloc] initWithData:errBuffer encoding:NSUTF8StringEncoding];
            log_error(@"%@", str);
            [str release];
        }
        
        int childStatus;
        ret = waitpid(child, &childStatus, WNOHANG | WUNTRACED);
        ret = (ret != 0 && WIFEXITED(childStatus)) ? WEXITSTATUS(childStatus) : EXIT_FAILURE;
        log_error(@"exit status of pid = %d was %d", child, ret);

    }
    
    [pool release];
    return ret;
}
