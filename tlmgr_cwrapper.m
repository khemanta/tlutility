/*
 *  tlmgr_cwrapper.c
 *  TeX Live Manager
 *
 *  Created by Adam Maxwell on 12/7/08.
 *
 This software is Copyright (c) 2008
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

#import <Foundation/Foundation.h>
#import "TLMLogMessage.h"
#include <asl.h>

#define SENDER_NAME @"com.googlecode.mactlmgr.tlmgr_cwrapper"

extern char **environ;

/* http://www.cocoabuilder.com/archive/message/cocoa/2001/6/15/21704 */

static id _logServer = nil;

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

static void log_message_with_level(const char *level, NSString *message)
{
    if (nil == _logServer) establish_log_connection();
    if (nil == _logServer) asl_log(NULL, NULL, ASL_LEVEL_ERR, "log_message_with_level: server is nil");
    
    TLMLogMessage *msg = [[TLMLogMessage alloc] init];
    [msg setDate:[NSDate date]];
    [msg setMessage:message];
    [msg setSender:SENDER_NAME];
    [msg setLevel:[NSString stringWithUTF8String:level]];
    [msg setPid:[NSNumber numberWithInteger:getpid()]];
    
    @try {
        [_logServer logMessage:msg];
    }
    @catch (id exception) {
        asl_log(NULL, NULL, ASL_LEVEL_ERR, "tlmgr_cwrapper: caught exception %s in log_notice", [[exception description] UTF8String]);
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
    log_message_with_level(ASL_STRING_NOTICE, message);
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
    log_message_with_level(ASL_STRING_ERR, message);
    [message release];
}
    
int main(int argc, char *argv[]) {
    
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    
    /* this call was the original purpose of the program */
    setuid(geteuid());
    
    /* 
     argv[0]: tlmgr_cwrapper
     argv[1]: y or n
     argv[2]: tlmgr
     argv[n]: tlmgr arguments
     */
    if (argc < 2) {
        log_error(@"insufficient arguments");
        exit(1);
    }
    
    /* Require a single character argument 'y' || 'n'.      */
    /* Don't accept 'yes' or 'no' or 'nitwit' as arguments. */
    char *c = argv[1];
    if (strlen(c) != 1 || ('y' != *c && 'n' != *c)) {
        log_error(@"first argument '%s' was not recognized", c);
        exit(1);
    }
    
    /* If yes, do what sudo -H does: read root's passwd entry and change HOME. */
    if ('y' == *c) {    
        struct passwd *pw = getpwuid(getuid());
        if (NULL == pw) {
            log_error(@"getpwuid failed in tlmgr_cwrapper");
            exit(1);
        }
        setenv("HOME", pw->pw_dir, 1);
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
    
    if (pipe(outpipe) < 0 || pipe(errpipe) < 0) {
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
    
    log_notice(@"tlmgr_cwrapper: HOME = '%s'\n", getenv("HOME"));

    int ret = 0;
    pid_t child = fork();
    if (0 == child) {
        i = execve(argv[2], &argv[2], environ);
        _exit(i);
    }
    else if (-1 == child) {
        perror("fork failed");
        exit(1);
    }
    else {
        
        char *line, buf[2048];        
        
        fd_set fdset;
        FD_ZERO(&fdset);
        FD_SET(outpipe[0], &fdset);
        FD_SET(errpipe[0], &fdset);
        
        struct timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = 100000;
        
        int max_fd = outpipe[0];
        if (errpipe[0] > max_fd) max_fd = errpipe[0];
        max_fd += 1;
        
        FILE *outstrm = fdopen(outpipe[0], "r");
        FILE *errstrm = fdopen(errpipe[0], "r");
        
        int childStatus;
        
        while (select(max_fd, &fdset, NULL, NULL, &tv) > 0 || waitpid(child, &childStatus, WNOHANG) == 0) {
            
            if (FD_ISSET(outpipe[0], &fdset)) {
                line = fgets(buf, sizeof(buf), outstrm);
                log_notice(@"%s", buf);
            }
            
            if (FD_ISSET(errpipe[0], &fdset)) {
                line = fgets(buf, sizeof(buf), errstrm);
                log_error(@"%s", buf);
            }
            
            FD_SET(outpipe[0], &fdset);
            FD_SET(errpipe[0], &fdset);
            
            // Original tlmgr commits suicide when it updates itself, and waitpid doesn't catch it (or I'm doing something wrong).  Polling the filesystem like this is gross, but it works.
            struct stat sb;
            if (stat(argv[2], &sb) != 0) {
                log_error(@"executable no longer exists at %s", argv[2]);
                kill(child, SIGTERM);
                exit(EXIT_FAILURE);
            }

            tv.tv_sec = 0;
            tv.tv_usec = 100000;
        }    
        fclose(errstrm);
        fclose(outstrm);
        
        ret = WIFEXITED(childStatus) ? WEXITSTATUS(childStatus) : EXIT_FAILURE;
    }
    
    [pool release];
    return ret;
}