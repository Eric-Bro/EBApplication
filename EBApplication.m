/*
 EBApplication.m
 Copyright (c) eric_bro, 2012 (eric.broska@me.com)
 
 Permission to use, copy, modify, and/or distribute this software for any
 purpose with or without fee is hereby granted, provided that the above
 copyright notice and this permission notice appear in all copies.
 
 THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

#import "EBApplication.h"
#include <objc/runtime.h>


/* 
 TODO_UI:   add "don't remind me later" checkbox 
 TODO_CODE: nil
 */

#define kEBDefaultApplicationFolderPath @"/Applications"
#define kEBXattrUtilutyDisableQuarantineCmdLine @"/usr/bin/xattr -d -r com.apple.quarantine"

static NSString *kEBApplicationShouldStartDirectlyKey = @"kEBApplicationShouldStartDirectlyKey";
static NSString *kEBApplcationOldBundlePathKey        = @"kEBApplcationOldBundlePathKey";
static NSString *kEBApplicationBundlePathKey          = @"kEBApplicationBundlePathKey";

/* Prototypes */
static int inject_nsbundle();
static int should_show_move_dialog();
static NSString* copy_bundle_to_applications_folder();
/* Custom +mainBundle implementation makes a right choose for a bundle path */
static id eb_mainBundle(id self, SEL _cmd);


int EBApplicationMain(int argc, const char **argv)
{
    int return_value = ERR_SUCCESS;
    if ( ! should_show_move_dialog()) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey: kEBApplicationBundlePathKey];
        return_value = NSApplicationMain(argc, argv);
    } else {
        /* Injecting NSBundle with the custom +mainBundle method.
           This method is using by all other Cocoa's classes (e.g. for loading some 
           GUI resources), so we have to care about a right path for the app's bundle. 
         */
        int success = inject_nsbundle();
        if (!success) {
            return NSApplicationMain(argc, argv);
        }
        
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        id app_name = [[[NSBundle mainBundle] infoDictionary] objectForKey: @"CFBundleDisplayName"];
        NSAlert *alert = [NSAlert alertWithMessageText: [NSString stringWithFormat: 
                                                         @"Should %@ move itself in the Application folder?", app_name] 
                                         defaultButton: @"Yeas, pls" 
                                       alternateButton: @"Nah" 
                                           otherButton: nil 
                             informativeTextWithFormat: @"blah-blah-blah"];
        
        if ([alert runModal] == NSOKButton) {
            
            NSString *new_bundle_path = copy_bundle_to_applications_folder();
            NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
            [ud setPersistentDomain:[NSDictionary dictionary] forName:[[NSBundle mainBundle] bundleIdentifier]];
            [ud setObject: [[NSBundle mainBundle] bundlePath]
                   forKey: kEBApplcationOldBundlePathKey];
            [ud setObject: [NSNumber numberWithBool: YES]
                   forKey: kEBApplicationShouldStartDirectlyKey];
            [ud setObject: new_bundle_path
                   forKey: kEBApplicationBundlePathKey];
            [ud synchronize];
            
            /* Run application from a new bundle */
            NSBundle *new_bunlde = [NSBundle bundleWithPath: new_bundle_path ];
            NSDictionary *bundle_info = [new_bunlde infoDictionary];
            Class principal_class = NSClassFromString([bundle_info objectForKey: @"NSPrincipalClass"]);
            NSApplication *new_app = [principal_class sharedApplication];
            NSNib *new_main_nib = [[NSNib alloc] 
                                   initWithNibNamed: [bundle_info objectForKey: @"NSMainNibFile"] 
                                             bundle: new_bunlde];
            [new_main_nib instantiateNibWithOwner: new_app topLevelObjects: nil];
            if ([new_app respondsToSelector: @selector(eb_run)]) {
                
                [new_app performSelectorOnMainThread: @selector(eb_run)
                                          withObject: nil
                                       waitUntilDone: YES];
            }
            [new_main_nib release];
        } else {
            return_value = NSApplicationMain(argc, argv);
        }
        [pool release];
    }
    return (return_value);
}

static int should_show_move_dialog()
{
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ( ![[[NSBundle mainBundle] bundlePath] hasPrefix: kEBDefaultApplicationFolderPath] 
        && ![ud objectForKey: kEBApplicationShouldStartDirectlyKey]) {
        return (1);
    } else {
        return (0);
    }
}

static NSString* copy_bundle_to_applications_folder()
{
    NSString *source = [[NSBundle mainBundle] bundlePath];
    NSString *dest = [NSString stringWithFormat:@"%@/%@", kEBDefaultApplicationFolderPath,
                      [source lastPathComponent]];
    NSError *error = nil;
    int success = [[NSFileManager defaultManager] copyItemAtPath: source 
                                                          toPath: dest  
                                                           error: &error];
    if (!success) {
        NSLog(@"%@", [error localizedDescription]);
        return (nil);
    }
    /* Use xattr to prevent "This file was downloaded from internet" dialog*/
    system([[NSString stringWithFormat: @"%@ %@", kEBXattrUtilutyDisableQuarantineCmdLine, dest] UTF8String]);
    return (dest);
}


@implementation NSApplication (MoveToApplicationsFolder)

- (void)eb_run
{    
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];    
    if ([ud objectForKey: kEBApplcationOldBundlePathKey]) {       
        NSError *error = nil;
        int success = [[NSFileManager defaultManager] 
                       removeItemAtPath: [ud objectForKey: kEBApplcationOldBundlePathKey] 
                                  error: &error];
        if (!success) {
            NSLog(@"%@", [error localizedDescription]);
        }
        [ud removeObjectForKey: kEBApplcationOldBundlePathKey];
    }
    [self run];
}
@end


#pragma mark NSBundle
/* --------------------------------------- */
/* Runtime hacks and NSBundle modding      */
/* --------------------------------------- */

@interface NSBundle (EBApplication)
+ (NSBundle *)__mainBundle;
@end

@implementation NSBundle (EBApplication)
static id _fakeBundle = nil;
@end

static id _cachedBundle(id self, SEL _cmd)
{
    return _fakeBundle;
}

static id eb_mainBundle(id self, SEL _cmd)
{
    @synchronized(self) {
        if (!_fakeBundle) {
            /* Try to read a right path from UD */
            NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
            id bundle_path = [ud objectForKey: kEBApplicationBundlePathKey];
            if (bundle_path) {
                _fakeBundle = [NSBundle bundleWithPath: bundle_path];
            } else {
                /* Or simple use the default method */
                _fakeBundle = [NSBundle __mainBundle];
            }
        } 
        if (_fakeBundle) {
            /* Replace implementation of this method (yes, again :)) for using a cached value
               instead of calculating $mainBundle each time method is invoked.
               This trick extremely (really) increases performance by avoiding @synchronized locks.
               If you wondering why @synchronize is bad - read this Google's articles:
                * http://googlemac.blogspot.com/2006/10/synchronized-swimming.html
                * http://googlemac.blogspot.com/2006/11/synchronized-swimming-part-2.html
               They are quite old (2006) but still relevant at all. 
             */
            Class metaClass = objc_getMetaClass(class_getName([self class]));
            const char* method_type_encoding = method_getTypeEncoding(class_getClassMethod(metaClass, @selector(mainBundle)));
            class_replaceMethod(metaClass, @selector(mainBundle), (IMP)_cachedBundle, method_type_encoding);
        }
    }
    return _fakeBundle;
} 

// Ideas of +mainBundle implementation was gotten from GNUStep's 
// 
//    NSLock *lock = [NSLock new];
//    [lock lock];
//    id bundle = nil;
//    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
//    id bundle_path = [ud objectForKey: kEBApplicationBundlePathKey];
//    if (bundle_path) {
//        bundle = [NSBundle bundleWithPath: bundle_path];
//    } else {
//        bundle = [NSBundle __mainBundle];
//    }
//    
//    [lock unlock];
//    return (bundle);


static int inject_nsbundle()
{
    Class NSBundleClass = NSClassFromString(@"NSBundle");
    /* We will use MetaClass for changing class methods.
      (Class' methods' names started with "+", instead of "-" for instance's):
    - (void)instanceMethod;
    + (void)classMethod;
     */
    Class NSBundleMetaClass = objc_getMetaClass(class_getName(NSBundleClass));
    const char* method_type_encoding = method_getTypeEncoding(class_getClassMethod(NSBundleMetaClass, @selector(mainBundle)));
    /* Because +mainBundle method is already exists - it will only replace an implementation with our own 
       and return an original implementation. 
     */
    IMP original_implementation = class_replaceMethod(NSBundleMetaClass, 
                                                      @selector(mainBundle), 
                                                      (IMP)eb_mainBundle, 
                                                      method_type_encoding);
    class_addMethod(NSBundleMetaClass, 
                    @selector(__mainBundle),
                    original_implementation,
                    method_type_encoding); 
    
    return (NULL != class_getClassMethod(NSBundleClass, @selector(__mainBundle)));
}