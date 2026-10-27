// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

// FilesArchiver 1.0.1
// Adds "Uncompress" and "Compress" to the Files app on iOS 12 (iOS 13 does this natively).
//
// Hook point (Files.app, com.apple.DocumentsApp, iOS 12):
//   -[DOCTabbedBrowserViewController viewDidLoad] / -setCustomActions:
// Files' main view controller (Files.DRIMainViewController) is a DOCTabbedBrowserViewController, which
// is a UIDocumentBrowserViewController. Its public `customActions` (UIDocumentBrowserAction, iOS 11)
// are what third-party document apps use to add items to the long-press menu; Files itself passes
// them to its in-process browser (DOCServiceBrowserViewController -hostProvidedActionsDidChange:).
// We append two actions there:
//   Uncompress  menu,               content types of the archive extensions, one item
//   Compress    menu + nav bar,      public.item (files and folders), one or more items
// The handler gets the items' file URLs. The archive work runs on a background queue
// (FAArchiver.m, libarchive) into a folder in Files' own tmp; the results are then handed to the
// location's File Provider with -importDocumentAtURL:nextToDocumentAtURL:mode:completionHandler:
// (public, iOS 12), so they show up at once and the provider's own rules apply. "Delete archive
// after extracting" uses the same FileProvider trash operation as Files' Delete. Before any work the
// destination folder's File Provider item is asked whether it accepts new items, so a job that could
// only fail at the end (top level of On My iPad, a read-only location) is refused at once.

#import <UIKit/UIKit.h>
#import <FileProvider/NSFileProviderItem.h>   // capability bits only (FileProvider is not linked)
#import <CoreServices/UTType.h>
#import <CoreServices/UTCoreTypes.h>
#import "FAArchiver.h"

#define kFADomain CFSTR("com.itsallexb.filesarchiver")
#define kFANotification "com.itsallexb.filesarchiver/prefschanged"
static NSString *const kFAPrefsPath = @"/var/mobile/Library/Preferences/com.itsallexb.filesarchiver.plist";
static NSString *const kFAUncompressID = @"com.itsallexb.filesarchiver.uncompress";
static NSString *const kFACompressID = @"com.itsallexb.filesarchiver.compress";

@interface DOCTabbedBrowserViewController : UIDocumentBrowserViewController
@end

// Troubleshooting log: written only if Files' tmp/filesarchiver.log already exists.
static void FALog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void FALog(NSString *fmt, ...) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"filesarchiver.log"];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    [h seekToEndOfFile];
    [h writeData:[[NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg] dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}

#pragma mark - Preferences

// Files is sandboxed: cfprefsd does not hand it another app's domain, but it may read
// ~/Library/Preferences, so the plist file is read directly (the settings pane writes it out
// before posting the change notification).
static id FAPref(NSString *key, id fallback) {
    id value = [NSDictionary dictionaryWithContentsOfFile:kFAPrefsPath][key];
    if (!value) value = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, kFADomain));
    return value ?: fallback;
}
static BOOL FAPrefBool(NSString *key, BOOL fallback) {
    id v = FAPref(key, nil);
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : fallback;
}
static FACompressFormat FACompressFormatPref(void) {
    NSString *v = FAPref(@"compressFormat", @"zip");
    if (![v isKindOfClass:[NSString class]]) return FACompressFormatZip;
    if ([v isEqualToString:@"tar.gz"]) return FACompressFormatTarGz;
    if ([v isEqualToString:@"7z"]) return FACompressFormat7z;
    return FACompressFormatZip;
}

#pragma mark - Progress UI

// A small alert with a progress bar and Cancel. Shown only if the job takes longer than 0.4 s,
// so small archives do not flash a dialog.
// A job can finish while the alert is still animating in; a dismiss sent then is dropped by UIKit,
// so -finish: waits for the presentation to complete, and a timer makes sure `then` runs regardless.
@interface FAProgressAlert : NSObject
@property (nonatomic, strong) UIAlertController *alert;
@property (nonatomic, strong) UIProgressView *bar;
@property (nonatomic, weak) UIViewController *host;
@property (nonatomic, assign) BOOL finished, presenting, presented;
@property (nonatomic, copy) NSString *itemName;
@property (nonatomic, copy) void (^then)(void);
@end

@implementation FAProgressAlert
+ (instancetype)alertWithTitle:(NSString *)title item:(NSString *)item host:(UIViewController *)host job:(FAJob *)job {
    FAProgressAlert *p = [FAProgressAlert new];
    p.host = host;
    p.itemName = item;
    p.alert = [UIAlertController alertControllerWithTitle:title message:[NSString stringWithFormat:@"%@\n\n", item] preferredStyle:UIAlertControllerStyleAlert];
    [p.alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) { job.cancelled = YES; }]];
    UIProgressView *bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [p.alert.view addSubview:bar];
    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:p.alert.view.leadingAnchor constant:24],
        [bar.trailingAnchor constraintEqualToAnchor:p.alert.view.trailingAnchor constant:-24],
        [bar.bottomAnchor constraintEqualToAnchor:p.alert.view.bottomAnchor constant:-62],
    ]];
    p.bar = bar;
    __weak FAProgressAlert *weak = p;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        FAProgressAlert *s = weak;
        if (!s || s.finished) return;
        UIViewController *top = s.host;
        if (!top) return;
        while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) top = top.presentedViewController;
        s.presenting = YES;
        [top presentViewController:s.alert animated:YES completion:^{
            s.presenting = NO;
            s.presented = YES;
            if (s.finished) [s dismissAndContinue];
        }];
    });
    return p;
}
- (void)setFraction:(double)fraction {
    if (fraction >= 0) [self.bar setProgress:(float)fraction animated:NO];
    self.alert.message = [NSString stringWithFormat:@"%@\n%d%%\n", self.itemName, (int)lround(fmax(fraction, 0) * 100)];
}
- (void)finish:(void (^)(void))then {
    if (self.finished) return;
    self.finished = YES;
    self.then = then;
    if (self.presenting) return;                 // continues in the presentation's completion
    if (self.presented) [self dismissAndContinue];
    else [self continueOnce];
}
- (void)dismissAndContinue {
    if (!self.alert.presentingViewController || self.alert.isBeingDismissed) { [self continueOnce]; return; }   // Cancel already closed it
    [self.alert dismissViewControllerAnimated:YES completion:^{ [self continueOnce]; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self continueOnce]; });
}
- (void)continueOnce {
    void (^t)(void) = self.then;
    self.then = nil;
    if (t) t();
}
@end

static UIViewController *FATopController(UIViewController *vc) {
    while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) vc = vc.presentedViewController;
    return vc;
}

static void FAShowMessage(UIViewController *host, NSString *title, NSString *message) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [FATopController(host) presentViewController:a animated:YES completion:nil];
}

// Shows the message now, or when Files is back in front.
static void FAShowMessageWhenActive(UIViewController *host, NSString *title, NSString *message) {
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) { FAShowMessage(host, title, message); return; }
    __block id token = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
                                                                         queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        [[NSNotificationCenter defaultCenter] removeObserver:token];
        token = nil;
        FAShowMessage(host, title, message);
    }];
}

#pragma mark - Jobs

static BOOL gBusy;

// Runs `work` off the main thread with a background task (Files may be sent to the background
// during a long job), a progress alert and the item's security scope. If the background time runs out
// the job is cancelled, the task ended right away (iOS requires it in the expiration handler) and a
// message is shown when Files comes back.
static void FARunJob(UIViewController *host, NSString *title, NSString *item, NSArray<NSURL *> *scoped,
                     id (^work)(FAJob *job, NSError **error), void (^done)(id result, NSError *error, FAJob *job)) {
    gBusy = YES;
    FAJob *job = [FAJob new];
    FAProgressAlert *progress = [FAProgressAlert alertWithTitle:title item:item host:host job:job];
    job.progressHandler = ^(double fraction, NSString *current) {
        dispatch_async(dispatch_get_main_queue(), ^{ [progress setFraction:fraction]; });
    };
    UIApplication *app = [UIApplication sharedApplication];
    __block BOOL expired = NO;
    __block UIBackgroundTaskIdentifier task = UIBackgroundTaskInvalid;
    task = [app beginBackgroundTaskWithName:@"FilesArchiver" expirationHandler:^{
        expired = YES;
        job.cancelled = YES;
        if (task != UIBackgroundTaskInvalid) { [app endBackgroundTask:task]; task = UIBackgroundTaskInvalid; }
    }];
    // The job runs inside a coordinated read, whose own process assertion has the same deadline and gets
    // Files killed (0x8badf00d) if the read is still open then. So stop well before the end.
    dispatch_source_t watch = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(watch, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 4);
    dispatch_source_set_event_handler(watch, ^{
        if (app.applicationState == UIApplicationStateBackground && app.backgroundTimeRemaining < 25 && !job.cancelled) {
            expired = YES;
            job.cancelled = YES;
        }
    });
    dispatch_resume(watch);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *started = [NSMutableArray array];
        for (NSURL *u in scoped) if ([u startAccessingSecurityScopedResource]) [started addObject:u];
        NSError *error = nil;
        id result = nil;
        @try {
            result = work(job, &error);
        } @catch (NSException *ex) {
            error = [NSError errorWithDomain:FAErrorDomain code:FAErrorIO userInfo:@{NSLocalizedDescriptionKey: ex.reason ?: ex.name}];
        }
        for (NSURL *u in started) [u stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_source_cancel(watch);
            [progress finish:^{
                gBusy = NO;
                done(result, error, job);           // a cancelled job only cleans up there
                if (expired && error.code == FAErrorCancelled)
                    FAShowMessageWhenActive(host, [title stringByAppendingString:@" Stopped"],
                        [NSString stringWithFormat:@"“%@” was not finished because Files was in the background for too long. Nothing was changed. Keep Files open until it is done.", item]);
                if (task != UIBackgroundTaskInvalid) { [app endBackgroundTask:task]; task = UIBackgroundTaskInvalid; }
            }];
        });
    });
}

// Per-job folder in Files' own temporary directory. Results are built there and then handed to
// the File Provider of the destination (see FAPlaceItems), never written into it directly.
static NSString *FAWorkRoot(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"FilesArchiver"];
}
static NSString *FANewWorkDir(void) {
    NSString *dir = [FAWorkRoot() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return dir;
}

// Moves finished items next to `neighbour` with the public iOS 12 API
// -[UIDocumentBrowserViewController importDocumentAtURL:nextToDocumentAtURL:mode:completionHandler:].
// The location's File Provider (On My iPad, iCloud Drive, third-party providers) then creates the
// items itself, with its own coordination rules, and Files lists them at once. Writing into
// "File Provider Storage" directly works on disk, but Files does not notice the new items.
static void FAPlaceItems(UIDocumentBrowserViewController *browser, NSArray<NSURL *> *items, NSURL *neighbour,
                         NSString *workDir, void (^done)(NSArray<NSURL *> *placed, NSError *error)) {
    NSMutableArray<NSURL *> *placed = [NSMutableArray array];
    __block NSError *firstError = nil;
    __block void (^next)(NSUInteger);
    __block __weak void (^weakNext)(NSUInteger);
    weakNext = next = ^(NSUInteger i) {
        if (i >= items.count) {
            [[NSFileManager defaultManager] removeItemAtPath:workDir error:NULL];
            done(placed, placed.count ? nil : firstError);
            next = nil;
            return;
        }
        NSURL *item = items[i];
        [browser importDocumentAtURL:item nextToDocumentAtURL:neighbour mode:UIDocumentBrowserImportModeMove
                   completionHandler:^(NSURL *imported, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                FALog(@"import %@ -> %@ (%@)", item.lastPathComponent, imported, error);
                if (imported) [placed addObject:imported];
                else {
                    NSLog(@"[FilesArchiver] import of %@ failed: %@", item.lastPathComponent, error);
                    if (!firstError) firstError = error;
                }
                weakNext(i + 1);
            });
        }];
    };
    next(0);
}

// Moves `url` to Recently Deleted through its File Provider, exactly like Files' own Delete
// (private FileProvider API: -[FPItemManager operationForAction:FPActionTrash items:] +
// -scheduleAction:). Never deletes permanently: if the provider refuses, `done` gets the error and
// the archive stays where it is. Called back on the main queue.
@interface FPItemManager : NSObject
+ (instancetype)defaultManager;
- (void)fetchItemForURL:(NSURL *)url completionHandler:(void (^)(id item, NSError *error))handler;
- (id)operationForAction:(NSString *)action items:(NSArray *)items;
- (void)scheduleAction:(id)operation;
@end
@interface NSObject (FAFPActionOperation)
- (void)setActionCompletionBlock:(void (^)(NSError *error))block; // the error only, nil on success
@end

static void FATrash(NSURL *url, void (^done)(NSError *error)) {
    void (^finish)(NSError *) = ^(NSError *error) { dispatch_async(dispatch_get_main_queue(), ^{ done(error); }); };
    Class manager = NSClassFromString(@"FPItemManager");
    if (![manager respondsToSelector:@selector(defaultManager)] ||
        ![manager instancesRespondToSelector:@selector(operationForAction:items:)] ||
        ![manager instancesRespondToSelector:@selector(scheduleAction:)]) {
        finish([NSError errorWithDomain:FAErrorDomain code:FAErrorIO userInfo:@{NSLocalizedDescriptionKey: @"Recently Deleted is not available."}]);
        return;
    }
    FPItemManager *m = [manager defaultManager];
    [m fetchItemForURL:url completionHandler:^(id item, NSError *error) {
        id op = item ? [m operationForAction:@"FPActionTrash" items:@[item]] : nil;
        FALog(@"trash %@: item=%@ error=%@ op=%@", url.lastPathComponent, item, error, op);
        if (!op) {
            finish(error ?: [NSError errorWithDomain:FAErrorDomain code:FAErrorIO userInfo:@{NSLocalizedDescriptionKey: @"The archive could not be found."}]);
            return;
        }
        if ([op respondsToSelector:@selector(setActionCompletionBlock:)]) {
            [op setActionCompletionBlock:^(NSError *opError) {
                FALog(@"trash %@ finished: error=%@", url.lastPathComponent, opError);
                finish(opError);
            }];
        }
        [m scheduleAction:op];
    }];
}

@interface NSObject (FAFPItem)
- (NSFileProviderItemCapabilities)capabilities;
@end
@interface FPItemManager (FAParent)
- (void)fetchParentForItem:(id)item completionHandler:(void (^)(id parent, NSError *error))handler;
@end

// Asks the File Provider whether the folder that holds `item` accepts new items. It does not at the top
// level of On My iPad (iOS 12's provider refuses imports there; the app folders shown there are really
// <app>/Documents, so the folder is found through the item's parent, not its URL) or in a read-only
// location such as FilesRoot's System. Unknown (private API missing, nothing found, no answer within
// 5 s) counts as yes: the import then reports any error. `done` runs once, on the main queue.
static void FACheckDestination(NSURL *item, void (^done)(BOOL ok)) {
    __block BOOL answered = NO;
    void (^finish)(BOOL) = ^(BOOL ok) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (!answered) { answered = YES; done(ok); } });
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ finish(YES); });
    void (^answer)(id, NSError *) = ^(id folder, NSError *error) {
        BOOL ok = YES;
        if ([folder respondsToSelector:@selector(capabilities)])
            ok = ([folder capabilities] & NSFileProviderItemCapabilitiesAllowsAddingSubItems) != 0;
        FALog(@"destination of %@: folder=%@ caps=0x%lx error=%@ -> %d", item.lastPathComponent, folder,
              [folder respondsToSelector:@selector(capabilities)] ? (unsigned long)[folder capabilities] : 0UL, error, ok);
        finish(ok);
    };
    Class manager = NSClassFromString(@"FPItemManager");
    if (![manager respondsToSelector:@selector(defaultManager)] || ![manager instancesRespondToSelector:@selector(fetchItemForURL:completionHandler:)]) {
        finish(YES);
        return;
    }
    FPItemManager *m = [manager defaultManager];
    if (![m respondsToSelector:@selector(fetchParentForItem:completionHandler:)]) {
        [m fetchItemForURL:item.URLByDeletingLastPathComponent completionHandler:answer];
        return;
    }
    [m fetchItemForURL:item completionHandler:^(id fpItem, NSError *error) {
        if (!fpItem) { answer(nil, error); return; }
        [m fetchParentForItem:fpItem completionHandler:answer];
    }];
}

static NSString *const kFANoNewItems = @"This location does not accept new items (for example the top level of On My iPad, or a read-only location).";

// What an extraction left out, by reason, as lines for the summary alert ("" when nothing).
static NSString *FASkipSummary(FAJob *job) {
    NSMutableArray *lines = [NSMutableArray array];
    void (^add)(NSUInteger, NSString *, NSString *) = ^(NSUInteger n, NSString *one, NSString *many) {
        if (n) [lines addObject:[NSString stringWithFormat:@"• %lu %@", (unsigned long)n, n == 1 ? one : many]];
    };
    add(job.skippedUnsafe, @"item could have been written outside the destination folder (“../” path or a link leading out).",
                           @"items could have been written outside the destination folder (“../” paths or links leading out).");
    add(job.skippedLongName, @"item has a name longer than iOS allows (255 bytes).", @"items have names longer than iOS allows (255 bytes).");
    add(job.skippedDeep, @"item is in folders nested too deeply for iOS.", @"items are in folders nested too deeply for iOS.");
    add(job.skippedClash, @"item clashed with another item of the same name.", @"items clashed with other items of the same name.");
    add(job.skippedSpecial, @"item is a device, pipe or socket, which can’t be created here.", @"items are devices, pipes or sockets, which can’t be created here.");
    add(job.failedEntries, @"item is damaged in the archive.", @"items are damaged in the archive.");
    if (job.damaged) [lines addObject:@"• The archive is damaged; anything after the damage is missing."];
    return [lines componentsJoinedByString:@"\n"];
}

static BOOL FACheckBusy(UIViewController *host) {
    if (!gBusy) return NO;
    FAShowMessage(host, @"Please Wait", @"Another archive is still being processed.");
    return YES;
}

// Coordinated read (downloads iCloud items first) around the extraction.
static NSArray<NSURL *> *FACoordinatedExtract(NSURL *archive, NSString *workDir, NSString *password, FAJob *job, NSError **outError) {
    __block NSArray *result = nil;
    __block NSError *error = nil;
    NSError *coordError = nil;
    BOOL intoFolder = FAPrefBool(@"extractIntoFolder", YES);
    BOOL skipMetadata = FAPrefBool(@"skipMetadata", YES);
    NSFileCoordinator *c = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    [c coordinateReadingItemAtURL:archive options:0 error:&coordError byAccessor:^(NSURL *url) {
        result = [FAArchiver extractArchive:url toDirectory:workDir intoFolder:intoFolder skipMetadata:skipMetadata passphrase:password job:job error:&error];
    }];
    if (outError) *outError = error ?: coordError;
    return result;
}

static void FAUncompress(UIDocumentBrowserViewController *host, NSURL *archive, NSString *password);
static void FAUncompressNow(UIDocumentBrowserViewController *host, NSURL *archive, NSString *password);

static void FAAskPassword(UIDocumentBrowserViewController *host, NSURL *archive, BOOL wrong) {
    NSString *name = archive.lastPathComponent;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:wrong ? @"Wrong Password" : @"Password Required"
        message:[NSString stringWithFormat:wrong ? @"The password for “%@” is not correct. Try again." : @"Enter the password for “%@”.", name]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.secureTextEntry = YES;
        f.placeholder = @"Password";
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weak = a;
    [a addAction:[UIAlertAction actionWithTitle:@"Uncompress" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *pw = weak.textFields.firstObject.text ?: @"";
        FAUncompress(host, archive, pw);
    }]];
    [FATopController(host) presentViewController:a animated:YES completion:nil];
}

static void FAUncompress(UIDocumentBrowserViewController *host, NSURL *archive, NSString *password) {
    if (FACheckBusy(host)) return;
    gBusy = YES;    // until the destination check answers
    FACheckDestination(archive, ^(BOOL ok) {
        gBusy = NO;
        if (!ok) { FAShowMessage(host, @"Cannot Uncompress", [kFANoNewItems stringByAppendingString:@" Move the archive into a folder where you can add files, then try again."]); return; }
        FAUncompressNow(host, archive, password);
    });
}

static void FAUncompressNow(UIDocumentBrowserViewController *host, NSURL *archive, NSString *password) {
    NSString *name = archive.lastPathComponent;
    NSString *workDir = FANewWorkDir();
    FARunJob(host, @"Uncompressing", name, @[archive, archive.URLByDeletingLastPathComponent],
        ^id(FAJob *job, NSError **error) {
            return FACoordinatedExtract(archive, workDir, password, job, error);
        },
        ^(NSArray<NSURL *> *results, NSError *error, FAJob *job) {
            if (!results) {
                [[NSFileManager defaultManager] removeItemAtPath:workDir error:NULL];
                if (error.code == FAErrorCancelled) return;
                if (error.code == FAErrorNeedsPassword || error.code == FAErrorWrongPassword) {
                    FAAskPassword(host, archive, error.code == FAErrorWrongPassword);
                    return;
                }
                FAShowMessage(host, error.code == FAErrorNoSpace ? @"Not Enough Space" : @"Cannot Uncompress", error.localizedDescription);
                return;
            }
            NSString *skipped = FASkipSummary(job);
            FAPlaceItems(host, results, archive, workDir, ^(NSArray<NSURL *> *placed, NSError *placeError) {
                if (placed.count < results.count) {
                    FAShowMessage(host, @"Cannot Uncompress", [NSString stringWithFormat:@"The extracted items could not be added next to “%@” (%@).", name, placeError.localizedDescription ?: @"unknown error"]);
                    return;
                }
                // Files hides names starting with a dot: say so, or a successful job looks like it did nothing.
                NSMutableArray *visible = [NSMutableArray array];
                for (NSURL *u in placed) if (![u.lastPathComponent hasPrefix:@"."]) [visible addObject:u];
                NSString *hidden = visible.count ? nil : [NSString stringWithFormat:@"“%@” only contained hidden items (%@), which Files does not show.",
                                                          name, [[placed valueForKey:@"lastPathComponent"] componentsJoinedByString:@", "]];
                if (skipped.length) {
                    NSString *msg = [NSString stringWithFormat:@"Not everything in “%@” was extracted:\n%@", name, skipped];
                    FAShowMessage(host, @"Some Items Were Skipped", hidden ? [NSString stringWithFormat:@"%@\n\n%@", msg, hidden] : msg);
                } else if (hidden) {
                    FAShowMessage(host, @"Only Hidden Items", hidden);
                }
                // Only once everything is in place; into Recently Deleted, so it can be recovered.
                if (FAPrefBool(@"deleteAfterExtract", NO)) {
                    FATrash(archive, ^(NSError *trashError) {
                        if (trashError) FAShowMessage(host, @"Archive Not Deleted",
                            [NSString stringWithFormat:@"“%@” was extracted but could not be moved to Recently Deleted (%@).", name, trashError.localizedDescription]);
                    });
                }
            });
        });
}

static void FACompressNow(UIDocumentBrowserViewController *host, NSArray<NSURL *> *items, FACompressFormat format, NSString *label, NSArray<NSURL *> *scoped);

static void FACompress(UIDocumentBrowserViewController *host, NSArray<NSURL *> *items) {
    if (FACheckBusy(host)) return;
    NSURL *parent = items.firstObject.URLByDeletingLastPathComponent;
    for (NSURL *u in items) {
        if (![u.URLByDeletingLastPathComponent.path isEqualToString:parent.path]) {
            FAShowMessage(host, @"Cannot Compress", @"Select items from one folder to compress them together.");
            return;
        }
    }
    FACompressFormat format = FACompressFormatPref();
    NSString *label = items.count == 1 ? items.firstObject.lastPathComponent : [NSString stringWithFormat:@"%lu items", (unsigned long)items.count];
    NSMutableArray *scoped = [items mutableCopy];
    [scoped addObject:parent];
    gBusy = YES;    // until the destination check answers
    FACheckDestination(items.firstObject, ^(BOOL ok) {
        gBusy = NO;
        if (!ok) { FAShowMessage(host, @"Cannot Compress", [kFANoNewItems stringByAppendingString:@" Move the items into a folder where you can add files, then try again."]); return; }
        FACompressNow(host, items, format, label, scoped);
    });
}

static void FACompressNow(UIDocumentBrowserViewController *host, NSArray<NSURL *> *items, FACompressFormat format, NSString *label, NSArray<NSURL *> *scoped) {
    NSString *workDir = FANewWorkDir();
    FARunJob(host, @"Compressing", label, scoped,
        ^id(FAJob *job, NSError **outError) {
            // Nested coordinated reads, one per selected item (this also downloads iCloud items),
            // with the archive written inside the innermost one.
            __block NSURL *result = nil;
            __block NSError *error = nil;
            __block NSError *coordError = nil;
            NSFileCoordinator *c = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
            __block void (^step)(NSUInteger);
            __block __weak void (^weakStep)(NSUInteger);
            weakStep = step = ^(NSUInteger i) {
                if (i == items.count) {
                    result = [FAArchiver compressItems:items format:format toDirectory:workDir job:job error:&error];
                    return;
                }
                NSError *e = nil;
                [c coordinateReadingItemAtURL:items[i] options:0 error:&e byAccessor:^(NSURL *url) { weakStep(i + 1); }];
                if (e && !coordError) coordError = e;
            };
            step(0);
            if (outError) *outError = error ?: coordError;
            return result;
        },
        ^(NSURL *result, NSError *error, FAJob *job) {
            if (!result) {
                [[NSFileManager defaultManager] removeItemAtPath:workDir error:NULL];
                if (error.code != FAErrorCancelled)
                    FAShowMessage(host, error.code == FAErrorNoSpace ? @"Not Enough Space" : @"Cannot Compress", error.localizedDescription);
                return;
            }
            FAPlaceItems(host, @[result], items.firstObject, workDir, ^(NSArray<NSURL *> *placed, NSError *placeError) {
                if (!placed.count)
                    FAShowMessage(host, @"Cannot Compress", [NSString stringWithFormat:@"The archive could not be added to the folder (%@).", placeError.localizedDescription ?: @"unknown error"]);
            });
        });
}

#pragma mark - Actions

static NSArray<NSString *> *FAArchiveContentTypes(void) {
    static NSArray *types;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableOrderedSet *set = [NSMutableOrderedSet orderedSet];
        NSSet *tooGeneric = [NSSet setWithObjects:@"public.data", @"public.item", @"public.content", @"public.archive", @"public.text", nil];
        for (NSString *ext in [FAArchiver archiveExtensions]) {
            // Files derives an item's type from its last extension, as here (".tar.gz" -> "gz").
            NSString *last = ext.pathExtension.length ? ext.pathExtension : ext;
            NSString *uti = CFBridgingRelease(UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)last, NULL));
            if (uti.length && ![tooGeneric containsObject:uti]) [set addObject:uti];
        }
        types = set.array;
    });
    return types;
}

static NSHashTable *gBrowsers;

static NSArray *FAOurActions(UIDocumentBrowserViewController *browser) {
    __weak UIDocumentBrowserViewController *weak = browser;
    UIDocumentBrowserAction *uncompress = [[UIDocumentBrowserAction alloc] initWithIdentifier:kFAUncompressID
        localizedTitle:@"Uncompress" availability:UIDocumentBrowserActionAvailabilityMenu handler:^(NSArray<NSURL *> *urls) {
            UIDocumentBrowserViewController *b = weak;
            NSURL *u = urls.firstObject;
            if (!b || !u) return;
            if (![FAArchiver isArchiveURL:u]) { FAShowMessage(b, @"Cannot Uncompress", @"This item is not an archive."); return; }
            FAUncompress(b, u, nil);
        }];
    uncompress.supportedContentTypes = FAArchiveContentTypes();
    uncompress.supportsMultipleItems = NO;

    UIDocumentBrowserAction *compress = [[UIDocumentBrowserAction alloc] initWithIdentifier:kFACompressID
        localizedTitle:@"Compress" availability:UIDocumentBrowserActionAvailabilityMenu | UIDocumentBrowserActionAvailabilityNavigationBar
        handler:^(NSArray<NSURL *> *urls) {
            UIDocumentBrowserViewController *b = weak;
            if (b && urls.count) FACompress(b, urls);
        }];
    compress.supportedContentTypes = @[(__bridge NSString *)kUTTypeItem];
    compress.supportsMultipleItems = YES;
    return @[uncompress, compress];
}

static NSArray *FAMergeActions(UIDocumentBrowserViewController *browser, NSArray *actions) {
    NSMutableArray *out = [NSMutableArray array];
    for (UIDocumentBrowserAction *a in actions) {
        if (![a.identifier hasPrefix:@"com.itsallexb.filesarchiver."]) [out addObject:a];
    }
    if (FAPrefBool(@"enabled", YES)) [out addObjectsFromArray:FAOurActions(browser)];
    return out;
}

%hook DOCTabbedBrowserViewController
- (void)viewDidLoad {
    %orig;
    [gBrowsers addObject:self];
    [self setCustomActions:self.customActions ?: @[]];
}
- (void)setCustomActions:(NSArray *)actions {
    %orig(FAMergeActions(self, actions));
}
%end

static void FAPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIDocumentBrowserViewController *b in gBrowsers.allObjects) [b setCustomActions:b.customActions ?: @[]];
    });
}

%ctor {
    gBrowsers = [NSHashTable weakObjectsHashTable];
    // Leftovers of a job that was interrupted (Files killed while working).
    [[NSFileManager defaultManager] removeItemAtPath:FAWorkRoot() error:NULL];
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, FAPrefsChanged,
                                    CFSTR(kFANotification), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}
