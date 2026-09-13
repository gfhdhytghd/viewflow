// Stable Launch Services identity for the separately updatable Rust receiver.
#import <Foundation/Foundation.h>
#include <signal.h>
#include <unistd.h>
static volatile sig_atomic_t child_pid;
static void terminate_child(int sig) { if(child_pid>0)kill(child_pid,sig); }
int main(int argc,const char* argv[]) {
  @autoreleasepool {
    if(argc<3)return 2;
    NSString* pidFile=[NSString stringWithUTF8String:argv[1]];
    [[NSString stringWithFormat:@"%d\n",getpid()] writeToFile:pidFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSTask* child=[NSTask new];
    child.executableURL=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];
    NSMutableArray* args=[NSMutableArray new];
    for(int i=3;i<argc;++i)[args addObject:[NSString stringWithUTF8String:argv[i]]];
    child.arguments=args;
    NSMutableDictionary* environment=[NSProcessInfo.processInfo.environment mutableCopy];
    environment[@"VIEWFLOW_CURSOR_FEEDBACK"]=@"1";
    child.environment=environment;
    child.standardOutput=NSFileHandle.fileHandleWithStandardOutput;
    child.standardError=NSFileHandle.fileHandleWithStandardError;
    signal(SIGTERM,terminate_child);signal(SIGINT,terminate_child);
    NSError* error=nil;
    if(![child launchAndReturnError:&error]) {fprintf(stderr,"input launcher: %s\n",error.localizedDescription.UTF8String);return 1;}
    child_pid=child.processIdentifier;[child waitUntilExit];child_pid=0;
    [[NSFileManager defaultManager] removeItemAtPath:pidFile error:nil];
    return child.terminationStatus;
  }
}
