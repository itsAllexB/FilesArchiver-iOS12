// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

// FilesArchiver archive engine (libarchive from Procursus, /usr/lib/libarchive.13.dylib).
//
// Extraction does NOT use archive_write_disk: entries are written by hand so every path can be
// checked first. The rules:
//  - entry names are split on "/" (and "\" for zip), empty and "." parts are dropped, so absolute
//    paths become relative; any ".." part makes the entry unsafe and it is skipped;
//  - everything is written into a fresh hidden staging folder (mkdtemp, short fixed name) inside the
//    destination folder, whose real path has no symlinks; intermediate folders are created with mkdir
//    and an existing non-folder in the way skips the entry;
//  - files are opened with O_NOFOLLOW | O_EXCL: nothing is ever written through an existing name. A name
//    that is taken (a repeated entry, or NFC/NFD "é": APFS is normalization-insensitive and libarchive
//    hands both over as NFC anyway) gets " 2", so both are kept; a hard link made from an earlier entry
//    is unlinked and replaced instead, like tar does;
//  - devices, fifos and sockets are skipped;
//  - symlinks are only created at the very end, relative ones only, and afterwards every symlink is
//    resolved with realpath(): it must lead strictly inside the top-level item it belongs to (the unit
//    that is moved into place, possibly renamed), otherwise it is removed;
//  - hard links must point at a regular file already extracted inside the staging folder;
//  - free space is checked as data is written; the job stops FAFreeSpaceReserve before the disk is full.
// Damaged entries are dropped and counted; everything else is kept. Only when reading has finished are
// the results renamed into the output folder (the tweak uses a folder in Files' tmp and then hands the
// results to the File Provider, see Tweak.x). Every per-entry loop has its own autorelease pool, so
// memory stays flat however many entries an archive has.
// Formats are enabled one by one; mtree is left out on purpose (see FAExtract).

#import "FAArchiver.h"
#import <archive.h>
#import <archive_entry.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <dirent.h>
#include <fcntl.h>
#include <fts.h>
#include <unistd.h>
#include <stdlib.h>
#include <errno.h>
#include <copyfile.h>
#include <xlocale.h>
#include <wchar.h>

NSString *const FAErrorDomain = @"com.itsallexb.filesarchiver";
const unsigned long long FAFreeSpaceReserve = 500ULL << 20;

static const size_t kFABlock = 256 * 1024;
// Free space is checked after this much data or this many entries (each file takes at least a block).
static const unsigned long long kFASpaceCheckBytes = 16ULL << 20;
static const NSUInteger kFASpaceCheckEntries = 256;
// Compress progress counts every entry as this many bytes, so thousands of small files still move the bar.
static const double kFAEntryWeight = 64 * 1024;
// Temporary names next to the results. Short and fixed: the folder is already private to the job.
static NSString *const kFATempTemplate = @".filesarchiver-XXXXXX";

@implementation FAJob
@end

static NSError *FAError(FAErrorCode code, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
static NSError *FAError(FAErrorCode code, NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    return [NSError errorWithDomain:FAErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: msg}];
}

static NSString *FAPosixText(int err) { return [NSString stringWithUTF8String:strerror(err)] ?: @"Unknown error"; }

static unsigned long long FAFreeBytes(NSString *path) {
    struct statfs fs;
    return statfs(path.fileSystemRepresentation, &fs) == 0 ? (unsigned long long)fs.f_bavail * fs.f_bsize : ULLONG_MAX;
}

static NSError *FANoSpaceError(void) {
    return FAError(FAErrorNoSpace, @"There is not enough free space. FilesArchiver stopped to keep at least %llu MB free and removed what it had written.",
                   FAFreeSpaceReserve >> 20);
}

// Throttles progress callbacks to ~10 per second.
typedef struct { CFAbsoluteTime last; } FAThrottle;
static void FAReport(FAJob *job, FAThrottle *t, double fraction, NSString *item, BOOL force) {
    if (!job.progressHandler) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!force && now - t->last < 0.1) return;
    t->last = now;
    job.progressHandler(fraction > 1 ? 1 : fraction, item);
}

static NSString *FARealPath(NSString *path) {
    char buf[PATH_MAX];
    if (!realpath(path.fileSystemRepresentation, buf)) return nil;
    return [NSString stringWithUTF8String:buf];
}

static NSArray<NSURL *> *FAExtract(Class self, NSURL *archiveURL, NSString *outputDirectory, BOOL intoFolder, BOOL skipMetadata,
                                   NSString *passphrase, FAJob *job, NSError **outError);
static NSURL *FACompress(Class self, NSArray<NSURL *> *items, FACompressFormat format, NSString *outputDirectory, FAJob *job, NSError **outError);

@implementation FAArchiver

#pragma mark - Names

+ (NSArray<NSString *> *)archiveExtensions {
    static NSArray *exts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        exts = @[ @"zip", @"7z", @"rar", @"tar", @"tgz", @"tar.gz", @"gz", @"tbz", @"tbz2", @"tar.bz2", @"bz2",
                  @"txz", @"tar.xz", @"xz", @"lzma", @"tlz", @"tar.lzma", @"tzst", @"tar.zst", @"zst", @"lz4",
                  @"tar.z", @"z", @"cpio", @"xar", @"iso", @"cab", @"lha", @"lzh", @"ar", @"deb", @"ipa",
                  @"cbz", @"cbr", @"cb7", @"cbt", @"jar", @"apk" ];
    });
    return exts;
}

// Longest known archive suffix of `name` (without the dot), or nil.
static NSString *FAArchiveSuffix(NSString *name) {
    NSString *lower = name.lowercaseString;
    NSString *best = nil;
    for (NSString *ext in [FAArchiver archiveExtensions]) {
        NSString *suffix = [@"." stringByAppendingString:ext];
        if (lower.length > suffix.length && [lower hasSuffix:suffix] && ext.length > best.length) best = ext;
    }
    return best;
}

+ (BOOL)isArchiveURL:(NSURL *)url {
    NSNumber *dir = nil;
    [url getResourceValue:&dir forKey:NSURLIsDirectoryKey error:NULL];
    if (dir.boolValue) return NO;
    return FAArchiveSuffix(url.lastPathComponent) != nil;
}

+ (NSString *)baseNameForArchiveName:(NSString *)name {
    NSString *suffix = FAArchiveSuffix(name);
    NSString *base = suffix ? [name substringToIndex:name.length - suffix.length - 1] : name.stringByDeletingPathExtension;
    // "Name.part1.rar" / "Name.part01.rar": multi-volume RAR naming.
    NSRange r = [base rangeOfString:@"\\.part[0-9]+$" options:NSRegularExpressionSearch | NSCaseInsensitiveSearch];
    if (r.location != NSNotFound && r.location > 0) base = [base substringToIndex:r.location];
    return base.length ? base : @"Archive";
}

static BOOL FANameIsFree(NSString *name, NSArray<NSString *> *dirs) {
    struct stat st;
    for (NSString *dir in dirs) {
        NSString *path = [dir stringByAppendingPathComponent:name];
        if (lstat(path.fileSystemRepresentation, &st) == 0 || errno != ENOENT) return NO;
    }
    return YES;
}

// stem + suffix, with the stem cut at a character boundary so the result fits in NAME_MAX (255) bytes.
static NSString *FAFitName(NSString *stem, NSString *suffix) {
    NSUInteger room = 255 - MIN(255, [suffix lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    while (stem.length && [stem lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > room)
        stem = [stem substringToIndex:[stem rangeOfComposedCharacterSequenceAtIndex:stem.length - 1].location];
    return [stem stringByAppendingString:suffix];
}

+ (NSString *)uniqueName:(NSString *)name inDirectories:(NSArray<NSString *> *)dirs {
    // Keep the whole archive suffix ("Name 2.tar.gz"), otherwise only the last extension.
    NSString *ext = FAArchiveSuffix(name) ?: name.pathExtension;
    NSString *stem = ext.length ? [name substringToIndex:name.length - ext.length - 1] : name;
    if (!stem.length) { stem = name; ext = @""; }
    NSString *dotExt = ext.length ? [@"." stringByAppendingString:ext] : @"";
    if ([name lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 255) name = FAFitName(stem, dotExt);
    if (FANameIsFree(name, dirs)) return name;
    for (NSUInteger i = 2; i < 10000; i++) {
        NSString *candidate = FAFitName(stem, [NSString stringWithFormat:@" %lu%@", (unsigned long)i, dotExt]);
        if (FANameIsFree(candidate, dirs)) return candidate;
    }
    return FAFitName(stem, [@" " stringByAppendingString:[NSUUID UUID].UUIDString]);
}

+ (NSString *)extensionForFormat:(FACompressFormat)format {
    switch (format) {
        case FACompressFormatTarGz: return @"tar.gz";
        case FACompressFormat7z: return @"7z";
        default: return @"zip";
    }
}

#pragma mark - Extraction helpers

static BOOL FAIsMetadata(NSArray<NSString *> *comps) {
    for (NSString *c in comps) {
        if ([c isEqualToString:@"__MACOSX"] || [c isEqualToString:@".DS_Store"] || [c hasPrefix:@"._"]) return YES;
    }
    return NO;
}

// Why an entry was not extracted (counted in FAJob).
typedef NS_ENUM(NSInteger, FASkip) { FASkipUnsafe, FASkipLongName, FASkipDeep, FASkipClash, FASkipSpecial };

static void FACountSkip(FAJob *job, FASkip why) {
    switch (why) {
        case FASkipLongName: job.skippedLongName++; break;
        case FASkipDeep: job.skippedDeep++; break;
        case FASkipClash: job.skippedClash++; break;
        case FASkipSpecial: job.skippedSpecial++; break;
        default: job.skippedUnsafe++; break;
    }
}

static FASkip FASkipForErrno(int err) {
    return (err == ENAMETOOLONG || err == ELOOP) ? FASkipDeep : (err == EEXIST || err == ENOTDIR) ? FASkipClash : FASkipUnsafe;
}

// Splits an archive path into components. nil means skip it, for the reason in *why (".." parts,
// names over 255 bytes, or a path too long below `root`).
static NSArray<NSString *> *FASafeComponents(NSString *path, BOOL backslashIsSeparator, NSString *root, FASkip *why) {
    *why = FASkipUnsafe;
    if (!path) return nil;
    if (backslashIsSeparator) path = [path stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    NSMutableArray *out = [NSMutableArray array];
    NSUInteger bytes = [root lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    for (NSString *c in [path componentsSeparatedByString:@"/"]) {
        if (c.length == 0 || [c isEqualToString:@"."]) continue;
        if ([c isEqualToString:@".."]) { *why = FASkipUnsafe; return nil; }
        NSUInteger n = [c lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        if (n > 255) { *why = FASkipLongName; return nil; }
        bytes += n + 1;
        [out addObject:c];
    }
    // Room for " 2"-style renames too. Checked up front so no chain of empty folders is left behind.
    if (bytes + 16 >= PATH_MAX) { *why = FASkipDeep; return nil; }
    return out;
}

// Path for a new file or hard link at `path`. A hard link from an earlier entry is unlinked (so nothing is
// written through it to the other name); anything else already there is kept and the new item gets " 2".
static NSString *FAFreePath(NSString *path, FAJob *job) {
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0) return path;
    if (S_ISREG(st.st_mode) && st.st_nlink > 1 && unlink(path.fileSystemRepresentation) == 0) return path;
    job.renamedClash++;
    NSString *dir = path.stringByDeletingLastPathComponent;
    return [dir stringByAppendingPathComponent:[FAArchiver uniqueName:path.lastPathComponent inDirectories:@[dir]]];
}

// Entry name as text: UTF-8 when libarchive can convert it, else its wide-character form (7z and
// rar store UTF-16), else the raw bytes as UTF-8, else as the old DOS code page of Windows zips.
static NSString *FAEntryString(const char *utf8, const wchar_t *wide, const char *raw) {
    if (utf8) { NSString *s = [NSString stringWithUTF8String:utf8]; if (s) return s; }
    if (wide) {
        NSString *s = [[NSString alloc] initWithBytes:wide length:wcslen(wide) * sizeof(wchar_t) encoding:NSUTF32LittleEndianStringEncoding];
        if (s.length) return s;
    }
    if (!raw) return nil;
    NSString *s = [NSString stringWithUTF8String:raw];
    if (s) return s;
    return [[NSString alloc] initWithCString:raw encoding:CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingDOSLatinUS)];
}

// Removes the folders FAEnsureDirs created for an entry that then failed, deepest first (only if empty).
static void FARemoveCreatedDirs(NSString *root, NSArray<NSString *> *comps, NSUInteger from, NSUInteger count) {
    for (NSUInteger n = count; n > from; n--)
        rmdir(FAJoin(root, [comps subarrayWithRange:NSMakeRange(0, n)]).fileSystemRepresentation);
}

// Creates root/comps[0]/.../comps[n-1] as real folders. NO if a non-folder (or symlink) is in the way or
// mkdir fails; *why says which, and folders created by this call are removed again.
static BOOL FAEnsureDirs(NSString *root, NSArray<NSString *> *comps, NSUInteger count, FASkip *why, NSUInteger *firstCreated) {
    NSString *path = root;
    NSUInteger created = NSNotFound;
    for (NSUInteger i = 0; i < count; i++) {
        path = [path stringByAppendingPathComponent:comps[i]];
        struct stat st;
        int err = 0;
        if (lstat(path.fileSystemRepresentation, &st) == 0) {
            if (S_ISDIR(st.st_mode)) continue;
            err = EEXIST;
        } else if (errno != ENOENT) {
            err = errno;
        } else if (mkdir(path.fileSystemRepresentation, 0755) != 0) {
            err = errno;
        } else {
            if (created == NSNotFound) created = i;
            continue;
        }
        if (why) *why = FASkipForErrno(err);
        if (created != NSNotFound) FARemoveCreatedDirs(root, comps, created, i);
        return NO;
    }
    if (firstCreated) *firstCreated = created == NSNotFound ? count : created;
    return YES;
}

static NSString *FAJoin(NSString *root, NSArray<NSString *> *comps) {
    NSString *p = root;
    for (NSString *c in comps) p = [p stringByAppendingPathComponent:c];
    return p;
}

static BOOL FAIsInside(NSString *path, NSString *root) {
    return [path isEqualToString:root] || [path hasPrefix:[root stringByAppendingString:@"/"]];
}

// Removes the symlinks in `links` (and from it) that do not resolve strictly inside the top-level item they
// belong to, or do not resolve at all, until nothing changes. The top-level items are what gets moved into
// place, each on its own and possibly renamed ("sib.txt" -> "sib 2.txt" next to the user's own "sib.txt"),
// so a link may not lead to a sibling, to its own top-level item ("dir/self -> .") or above it
// ("dir/up -> .."). `wrapped`: everything is moved as one new folder, which is then the only top-level item.
static NSUInteger FAPruneSymlinks(NSString *root, NSMutableArray<NSString *> *links, BOOL wrapped) {
    NSUInteger removed = 0;
    BOOL changed = YES;
    while (changed) {
        changed = NO;
        for (NSString *link in [links copy]) {
            NSArray *rel = [[link substringFromIndex:root.length + 1] componentsSeparatedByString:@"/"];
            NSString *top = wrapped ? root : (rel.count > 1 ? FARealPath([root stringByAppendingPathComponent:rel[0]]) : nil);
            NSString *real = top ? FARealPath(link) : nil;
            if (!real || !FAIsInside(real, top) || [real isEqualToString:top]) {
                unlink(link.fileSystemRepresentation);
                [links removeObject:link];
                removed++;
                changed = YES;
            }
        }
    }
    return removed;
}

// Names in `root`, sorted.
static NSArray<NSString *> *FATopItems(NSString *root) {
    return [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:root error:NULL] sortedArrayUsingSelector:@selector(compare:)] ?: @[];
}

static void FASetTimes(NSString *path, struct archive_entry *e, BOOL isLink) {
    if (!archive_entry_mtime_is_set(e)) return;
    struct timespec ts[2];
    ts[1].tv_sec = archive_entry_mtime(e);
    ts[1].tv_nsec = archive_entry_mtime_nsec(e);
    ts[0] = ts[1];
    if (archive_entry_atime_is_set(e)) { ts[0].tv_sec = archive_entry_atime(e); ts[0].tv_nsec = archive_entry_atime_nsec(e); }
    utimensat(AT_FDCWD, path.fileSystemRepresentation, ts, isLink ? AT_SYMLINK_NOFOLLOW : 0);
}

static BOOL FAIsEncryptionUnsupportedFormat(int fmt) {
    int family = fmt & ARCHIVE_FORMAT_BASE_MASK;
    return family == ARCHIVE_FORMAT_7ZIP || family == ARCHIVE_FORMAT_RAR || family == ARCHIVE_FORMAT_RAR_V5;
}

// Apps run in the "C" locale, in which libarchive cannot convert non-ASCII names between UTF-8,
// UTF-16 (7z, rar) and wide strings. Switch only the worker thread to a UTF-8 locale.
static locale_t FAUTF8Locale(void) {
    static locale_t loc;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        loc = newlocale(LC_CTYPE_MASK, "UTF-8", NULL);
        if (!loc) loc = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", NULL);
    });
    return loc;
}

#pragma mark - Extraction

+ (NSArray<NSURL *> *)extractArchive:(NSURL *)archiveURL
                         toDirectory:(NSString *)outputDirectory
                          intoFolder:(BOOL)intoFolder
                        skipMetadata:(BOOL)skipMetadata
                          passphrase:(NSString *)passphrase
                                 job:(FAJob *)job
                               error:(NSError **)outError {
    locale_t utf8 = FAUTF8Locale(), old = utf8 ? uselocale(utf8) : NULL;
    NSArray *r = FAExtract(self, archiveURL, outputDirectory, intoFolder, skipMetadata, passphrase, job, outError);
    if (utf8) uselocale(old);
    return r;
}

static NSArray<NSURL *> *FAExtract(Class self, NSURL *archiveURL, NSString *outputDirectory, BOOL intoFolder, BOOL skipMetadata,
                                   NSString *passphrase, FAJob *job, NSError **outError) {
    NSString *archivePath = FARealPath(archiveURL.path);
    NSString *parent = archivePath.stringByDeletingLastPathComponent;
    if (!archivePath || !parent.length) {
        if (outError) *outError = FAError(FAErrorIO, @"The archive could not be found.");
        return nil;
    }
    struct stat ast;
    if (stat(archivePath.fileSystemRepresentation, &ast) != 0) {
        if (outError) *outError = FAError(FAErrorIO, @"The archive could not be read (%@).", FAPosixText(errno));
        return nil;
    }
    double total = ast.st_size > 0 ? (double)ast.st_size : 1;
    NSString *outDir = outputDirectory ? FARealPath(outputDirectory) : parent;
    if (!outDir) {
        if (outError) *outError = FAError(FAErrorIO, @"The destination folder could not be found.");
        return nil;
    }
    if (FAFreeBytes(outDir) < FAFreeSpaceReserve) {
        if (outError) *outError = FANoSpaceError();
        return nil;
    }
    NSArray *nameDirs = [outDir isEqualToString:parent] ? @[parent] : @[parent, outDir];
    NSString *archiveName = archivePath.lastPathComponent;
    NSString *base = [self baseNameForArchiveName:archiveName];

    // Hidden staging folder next to the results, so the final step is a rename on the same volume.
    char *tmpl = strdup([outDir stringByAppendingPathComponent:kFATempTemplate].fileSystemRepresentation);
    if (!mkdtemp(tmpl)) {
        int err = errno;
        free(tmpl);
        if (outError) *outError = FAError(FAErrorIO, @"Could not create a folder next to the archive (%@).", FAPosixText(err));
        return nil;
    }
    NSString *staging = [NSString stringWithUTF8String:tmpl];
    free(tmpl);
    NSString *root = FARealPath(staging) ?: staging;

    struct archive *a = archive_read_new();
    archive_read_support_filter_all(a);
    // Not archive_read_support_format_all(): that includes mtree, a text format that would take
    // any text file as an "archive" and whose entries can name files elsewhere on disk to read.
    archive_read_support_format_7zip(a);
    archive_read_support_format_ar(a);
    archive_read_support_format_cab(a);
    archive_read_support_format_cpio(a);
    archive_read_support_format_iso9660(a);
    archive_read_support_format_lha(a);
    archive_read_support_format_rar(a);
    archive_read_support_format_rar5(a);
    archive_read_support_format_tar(a);
    archive_read_support_format_xar(a);
    archive_read_support_format_zip(a);
    archive_read_support_format_raw(a); // lowest bid: only wins for plain .gz/.bz2/.xz... files
    if (passphrase.length) archive_read_add_passphrase(a, passphrase.UTF8String);

    NSError *error = nil;
    NSString *damage = nil;                                 // libarchive's text for the first damaged entry
    NSMutableArray<NSString *> *links = [NSMutableArray array];
    NSMutableArray *deferredLinks = [NSMutableArray array]; // @[comps, target]
    NSMutableArray *dirTimes = [NSMutableArray array];      // @[path, NSValue timespec]
    BOOL isRaw = NO;
    NSUInteger entries = 0;
    unsigned long long sinceSpaceCheck = 0;
    FAThrottle throttle = {0};

    if (archive_read_open_filename(a, archivePath.fileSystemRepresentation, 64 * 1024) != ARCHIVE_OK) {
        const char *msg = archive_error_string(a);
        error = FAError(FAErrorUnsupported, @"“%@” is not an archive FilesArchiver can open%@.", archiveName,
                        msg ? [NSString stringWithFormat:@" (%s)", msg] : @"");
    }

    struct archive_entry *e = NULL;
    BOOL stop = NO;
    while (!error && !stop) @autoreleasepool {
        if (job.cancelled) { error = FAError(FAErrorCancelled, @"Cancelled."); break; }
        int r = archive_read_next_header(a, &e);
        if (r == ARCHIVE_EOF) break;
        if (r < ARCHIVE_WARN) {
            const char *msg = archive_error_string(a);
            NSString *text = msg ? @(msg) : @"unknown error";
            if (passphrase.length == 0 && [text rangeOfString:@"encrypt" options:NSCaseInsensitiveSearch].location != NSNotFound)
                error = FAError(FAErrorEncryptedUnsupported, @"“%@” is encrypted in a way FilesArchiver cannot open (%@).", archiveName, text);
            else if (entries == 0)
                error = FAError(FAErrorUnsupported, @"“%@” is damaged or not a supported archive (%@).", archiveName, text);
            else {
                // The rest can't be read: keep what came before.
                job.damaged = YES;
                if (!damage) damage = text;
            }
            break;
        }
        int fmt = archive_format(a);
        if (entries == 0 && fmt == ARCHIVE_FORMAT_RAW) {
            // A lone compressed stream (.gz, .bz2, .xz...). With no compression filter at all,
            // the file is simply not an archive.
            if (archive_filter_count(a) <= 1 || archive_filter_code(a, 0) == ARCHIVE_FILTER_NONE) {
                error = FAError(FAErrorUnsupported, @"“%@” is damaged or not a supported archive.", archiveName);
                break;
            }
            isRaw = YES;
        }
        entries++;
        if (entries % kFASpaceCheckEntries == 0 && FAFreeBytes(root) < FAFreeSpaceReserve) { error = FANoSpaceError(); break; }

        NSArray<NSString *> *comps;
        FASkip why = FASkipUnsafe;
        if (isRaw) {
            NSString *suffix = archiveName.pathExtension;
            NSString *name = suffix.length ? archiveName.stringByDeletingPathExtension : [archiveName stringByAppendingString:@" (uncompressed)"];
            comps = @[name];
        } else {
            NSString *name = FAEntryString(archive_entry_pathname_utf8(e), archive_entry_pathname_w(e), archive_entry_pathname(e));
            BOOL isZip = (fmt & ARCHIVE_FORMAT_BASE_MASK) == ARCHIVE_FORMAT_ZIP;
            comps = FASafeComponents(name, isZip, root, &why);
            if (!comps) { FACountSkip(job, why); continue; }
            if (comps.count == 0) continue; // "./" or "/"
            if (skipMetadata && FAIsMetadata(comps)) { job.skippedMetadata++; continue; }
        }
        NSString *path = FAJoin(root, comps);
        NSString *display = comps.lastObject;
        FAReport(job, &throttle, archive_filter_bytes(a, -1) / total, display, NO);

        if (archive_entry_is_encrypted(e) && FAIsEncryptionUnsupportedFormat(fmt)) {
            error = FAError(FAErrorEncryptedUnsupported, @"“%@” is password protected. FilesArchiver can only open password-protected zip archives.", archiveName);
            break;
        }

        mode_t type = archive_entry_filetype(e);
        const char *hardlink = archive_entry_hardlink(e);
        if (type == AE_IFDIR) {
            if (!FAEnsureDirs(root, comps, comps.count, &why, NULL)) { FACountSkip(job, why); continue; }
            if (archive_entry_mtime_is_set(e)) {
                struct timespec ts = { archive_entry_mtime(e), archive_entry_mtime_nsec(e) };
                [dirTimes addObject:@[path, [NSValue valueWithBytes:&ts objCType:@encode(struct timespec)]]];
            }
            continue;
        }
        if (type == AE_IFLNK) {
            NSString *target = FAEntryString(archive_entry_symlink_utf8(e), archive_entry_symlink_w(e), archive_entry_symlink(e));
            // Only relative targets; absolute ones would point outside the folder by definition.
            if (!target.length || [target hasPrefix:@"/"]) { job.skippedUnsafe++; continue; }
            [deferredLinks addObject:@[comps, target]];
            continue;
        }
        if (type != AE_IFREG && type != 0 && !hardlink) { job.skippedSpecial++; continue; } // devices, fifos, sockets
        NSUInteger firstCreated = 0;
        if (!FAEnsureDirs(root, comps, comps.count - 1, &why, &firstCreated)) { FACountSkip(job, why); continue; }

        if (hardlink && archive_entry_size(e) <= 0) {
            NSString *t = FAEntryString(archive_entry_hardlink_utf8(e), archive_entry_hardlink_w(e), hardlink);
            FASkip twhy;
            NSArray *tcomps = FASafeComponents(t, NO, root, &twhy);
            NSString *tpath = tcomps.count ? FAJoin(root, tcomps) : nil;
            struct stat st;
            if (!tpath || lstat(tpath.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode)) {
                job.skippedUnsafe++;
                FARemoveCreatedDirs(root, comps, firstCreated, comps.count - 1);
                continue;
            }
            path = FAFreePath(path, job);
            if (link(tpath.fileSystemRepresentation, path.fileSystemRepresentation) != 0 &&
                copyfile(tpath.fileSystemRepresentation, path.fileSystemRepresentation, NULL, COPYFILE_DATA | COPYFILE_NOFOLLOW | COPYFILE_EXCL) != 0) {
                FACountSkip(job, FASkipForErrno(errno));
            }
            continue;
        }
        if (type != AE_IFREG && type != 0) { job.skippedSpecial++; continue; }

        path = FAFreePath(path, job);
        int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
        if (fd < 0) {
            int err = errno;
            if (err == ENAMETOOLONG || err == EEXIST || err == EISDIR || err == ELOOP) {
                FACountSkip(job, FASkipForErrno(err));
                FARemoveCreatedDirs(root, comps, firstCreated, comps.count - 1);
                continue;
            }
            error = FAError(FAErrorIO, @"Could not write “%@” (%@).", display, FAPosixText(err));
            break;
        }
        const void *block; size_t size; la_int64_t offset; la_int64_t end = 0;
        int rr;
        while ((rr = archive_read_data_block(a, &block, &size, &offset)) == ARCHIVE_OK) {
            if (job.cancelled) break;
            const char *p = block; size_t left = size; off_t at = offset;
            while (left > 0) {
                ssize_t w = pwrite(fd, p, left, at);
                if (w < 0) { if (errno == EINTR) continue; break; }
                p += w; left -= (size_t)w; at += w;
            }
            if (left > 0) {
                rr = ARCHIVE_FATAL;
                error = errno == ENOSPC ? FANoSpaceError() : FAError(FAErrorIO, @"Could not write “%@” (%@).", display, FAPosixText(errno));
                break;
            }
            if (offset + (la_int64_t)size > end) end = offset + (la_int64_t)size;
            sinceSpaceCheck += size;
            if (sinceSpaceCheck >= kFASpaceCheckBytes) {
                sinceSpaceCheck = 0;
                if (FAFreeBytes(root) < FAFreeSpaceReserve) { rr = ARCHIVE_FATAL; error = FANoSpaceError(); break; }
            }
            FAReport(job, &throttle, archive_filter_bytes(a, -1) / total, display, NO);
        }
        if (!error && job.cancelled) error = FAError(FAErrorCancelled, @"Cancelled.");
        BOOL failed = NO;
        if (!error && rr != ARCHIVE_EOF) {
            const char *msg = archive_error_string(a);
            NSString *text = msg ? @(msg) : @"unknown error";
            if (archive_entry_is_data_encrypted(e) && !FAIsEncryptionUnsupportedFormat(fmt)) {
                error = passphrase.length
                    ? FAError(FAErrorWrongPassword, @"The password for “%@” is not correct.", archiveName)
                    : FAError(FAErrorNeedsPassword, @"“%@” is password protected.", archiveName);
            } else if (archive_entry_is_data_encrypted(e)) {
                error = FAError(FAErrorEncryptedUnsupported, @"“%@” is password protected. FilesArchiver can only open password-protected zip archives.", archiveName);
            } else if (FAIsEncryptionUnsupportedFormat(fmt)) {
                // libarchive does not always flag encrypted RAR5 entries; it just fails to decode.
                error = FAError(FAErrorIO, @"Could not extract “%@” (%@). If “%@” is password protected: FilesArchiver can only open password-protected zip archives.", display, text, archiveName);
            } else {
                // A damaged entry (bad CRC, truncated data): drop it, keep the others.
                failed = YES;
                job.failedEntries++;
                if (!damage) damage = text;
                if (rr == ARCHIVE_FATAL) { job.damaged = YES; stop = YES; }
            }
        }
        if (!error && !failed) {
            if (archive_entry_size_is_set(e) && archive_entry_size(e) > end) end = archive_entry_size(e);
            ftruncate(fd, end); // trailing holes of sparse files
            mode_t mode = archive_entry_perm(e);
            fchmod(fd, (mode & 0111) ? 0755 : 0644);
        }
        close(fd);
        if (failed) unlink(path.fileSystemRepresentation);
        else if (!error) FASetTimes(path, e, NO);
    }

    if (!error && entries == 0) error = FAError(FAErrorEmpty, @"“%@” is empty.", archiveName);
    if (!error) {
        for (NSArray *item in deferredLinks) @autoreleasepool {
            NSArray<NSString *> *comps = item[0];
            NSString *path = FAJoin(root, comps);
            struct stat st;
            FASkip why;
            if (!FAEnsureDirs(root, comps, comps.count - 1, &why, NULL)) { FACountSkip(job, why); continue; }
            // Something already has this name (a file from the archive, or an equal-to-the-filesystem name): keep it.
            if (lstat(path.fileSystemRepresentation, &st) == 0) { job.skippedClash++; continue; }
            if (symlink([item[1] fileSystemRepresentation], path.fileSystemRepresentation) == 0) [links addObject:path];
            else FACountSkip(job, FASkipForErrno(errno));
        }
        // Which items are moved as a whole decides where links may point (see FAPruneSymlinks). Removing a
        // top-level link can change that decision, so repeat until it is stable.
        BOOL wrapped = NO;
        for (int pass = 0; pass < 3; pass++) {
            NSArray *top = FATopItems(root);
            BOOL w = intoFolder && top.count > 1 && !isRaw;
            if (pass > 0 && w == wrapped) break;
            wrapped = w;
            job.skippedUnsafe += FAPruneSymlinks(root, links, wrapped);
        }
        // Folder times last, deepest first, because writing into a folder changes its mtime.
        for (NSArray *d in [dirTimes reverseObjectEnumerator]) {
            struct timespec ts[2];
            [d[1] getValue:&ts[1]];
            ts[0] = ts[1];
            utimensat(AT_FDCWD, [d[0] fileSystemRepresentation], ts, AT_SYMLINK_NOFOLLOW);
        }
    }
    archive_read_free(a);

    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSURL *> *results = [NSMutableArray array];
    if (!error) {
        NSArray *top = FATopItems(root);
        if (top.count == 0) {
            if (damage) error = FAError(FAErrorIO, @"“%@” is damaged; nothing could be extracted (%@).", archiveName, damage);
            else error = FAError(FAErrorEmpty, (job.skippedUnsafe || job.skippedLongName || job.skippedDeep || job.skippedClash || job.skippedSpecial)
                                 ? @"“%@” contains nothing that can be extracted safely." : @"“%@” is empty.", archiveName);
        } else if (intoFolder && top.count > 1 && !isRaw) {
            NSString *name = [self uniqueName:base inDirectories:nameDirs];
            NSString *dest = [outDir stringByAppendingPathComponent:name];
            chmod(root.fileSystemRepresentation, 0755);
            if (rename(root.fileSystemRepresentation, dest.fileSystemRepresentation) == 0) {
                [results addObject:[NSURL fileURLWithPath:dest isDirectory:YES]];
                root = nil;
            } else {
                error = FAError(FAErrorIO, @"Could not create “%@” (%@).", name, FAPosixText(errno));
            }
        } else {
            for (NSString *child in top) {
                NSString *name = [self uniqueName:child inDirectories:nameDirs];
                NSString *dest = [outDir stringByAppendingPathComponent:name];
                if (rename([root stringByAppendingPathComponent:child].fileSystemRepresentation, dest.fileSystemRepresentation) == 0) {
                    [results addObject:[NSURL fileURLWithPath:dest]];
                } else if (!error) {
                    error = FAError(FAErrorIO, @"Could not create “%@” (%@).", name, FAPosixText(errno));
                }
            }
        }
    }
    if (root) [fm removeItemAtPath:root error:NULL];
    if (error && results.count == 0) {
        if (outError) *outError = error;
        return nil;
    }
    FAReport(job, &throttle, 1, nil, YES);
    return results;
}

#pragma mark - Compression

// Visits every selected item (itself and, for a folder, everything inside; symlinks are not followed) with
// its path, its name inside the archive and its lstat() info, until `visit` returns NO or the job is
// cancelled. Our own temporary items are skipped. Nothing is kept per entry, so memory does not grow with
// the number of files.
static void FAWalk(NSArray<NSURL *> *items, FAJob *job, BOOL (^visit)(const char *abs, NSString *rel, const struct stat *st)) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSURL *item in items) {
        NSString *top = FARealPath(item.path);
        if (!top) continue;
        NSString *prefix = top.lastPathComponent;
        char *paths[] = { strdup(top.fileSystemRepresentation), NULL };
        size_t topLen = strlen(paths[0]);
        FTS *fts = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
        BOOL go = fts != NULL;
        FTSENT *f;
        while (go && !job.cancelled && (f = fts_read(fts))) @autoreleasepool {
            if (f->fts_info == FTS_DP || f->fts_info == FTS_NS || f->fts_info == FTS_NSOK || f->fts_info == FTS_ERR) continue;
            if (f->fts_level > 0 && strstr(f->fts_name, ".filesarchiver-")) {
                if (f->fts_info == FTS_D) fts_set(fts, f, FTS_SKIP);
                continue;
            }
            NSString *rel = prefix;
            if (f->fts_level > 0) rel = [prefix stringByAppendingString:[fm stringWithFileSystemRepresentation:f->fts_path + topLen length:strlen(f->fts_path + topLen)]];
            go = visit(f->fts_path, rel, f->fts_statp);
        }
        if (fts) fts_close(fts);
        free(paths[0]);
        if (!go) break;
    }
}

+ (NSURL *)compressItems:(NSArray<NSURL *> *)items format:(FACompressFormat)format toDirectory:(NSString *)outputDirectory job:(FAJob *)job error:(NSError **)outError {
    locale_t utf8 = FAUTF8Locale(), old = utf8 ? uselocale(utf8) : NULL;
    NSURL *r = FACompress(self, items, format, outputDirectory, job, outError);
    if (utf8) uselocale(old);
    return r;
}

static NSURL *FACompress(Class self, NSArray<NSURL *> *items, FACompressFormat format, NSString *outputDirectory, FAJob *job, NSError **outError) {
    if (items.count == 0) return nil;
    NSString *parent = FARealPath(items.firstObject.path.stringByDeletingLastPathComponent);
    if (!parent) {
        if (outError) *outError = FAError(FAErrorIO, @"The selected items could not be found.");
        return nil;
    }
    NSString *outDir = outputDirectory ? FARealPath(outputDirectory) : parent;
    if (!outDir) {
        if (outError) *outError = FAError(FAErrorIO, @"The destination folder could not be found.");
        return nil;
    }
    if (FAFreeBytes(outDir) < FAFreeSpaceReserve) {
        if (outError) *outError = FANoSpaceError();
        return nil;
    }
    NSArray *nameDirs = [outDir isEqualToString:parent] ? @[parent] : @[parent, outDir];
    NSString *ext = [self extensionForFormat:format];
    NSString *stem = @"Archive";
    if (items.count == 1) {
        NSString *name = items.firstObject.lastPathComponent;
        NSNumber *dir = nil;
        [items.firstObject getResourceValue:&dir forKey:NSURLIsDirectoryKey error:NULL];
        stem = (dir.boolValue || !name.pathExtension.length || !name.stringByDeletingPathExtension.length) ? name : name.stringByDeletingPathExtension;
    }
    NSString *finalName = [self uniqueName:[NSString stringWithFormat:@"%@.%@", stem, ext] inDirectories:nameDirs];

    // Pass 1 only measures (bytes, plus kFAEntryWeight per entry) for the progress bar; pass 2 writes.
    __block double total = 0;
    __block NSUInteger entries = 0;
    FAWalk(items, job, ^BOOL(const char *abs, NSString *rel, const struct stat *st) {
        entries++;
        total += S_ISREG(st->st_mode) ? st->st_size : 0;
        return YES;
    });
    if (job.cancelled) { if (outError) *outError = FAError(FAErrorCancelled, @"Cancelled."); return nil; }
    if (entries == 0) { if (outError) *outError = FAError(FAErrorIO, @"The selected items could not be read."); return nil; }
    total += entries * kFAEntryWeight;

    char *tmpl = strdup([outDir stringByAppendingPathComponent:kFATempTemplate].fileSystemRepresentation);
    int tfd = mkstemp(tmpl);
    if (tfd < 0) {
        int err = errno;
        free(tmpl);
        if (outError) *outError = FAError(FAErrorIO, @"Could not create the archive (%@).", FAPosixText(err));
        return nil;
    }
    close(tfd);
    NSString *tmpPath = [NSString stringWithUTF8String:tmpl];
    free(tmpl);

    struct archive *a = archive_write_new();
    switch (format) {
        case FACompressFormatTarGz:
            archive_write_set_format_pax_restricted(a);
            archive_write_add_filter_gzip(a);
            break;
        case FACompressFormat7z:
            archive_write_set_format_7zip(a);
            archive_write_set_format_option(a, "7zip", "compression", "lzma2");
            archive_write_set_format_option(a, "7zip", "compression-level", "5");
            break;
        default:
            archive_write_set_format_zip(a);
            archive_write_set_format_option(a, "zip", "compression", "deflate");
            archive_write_set_format_option(a, "zip", "hdrcharset", "UTF-8");
            break;
    }
    __block NSError *error = nil;
    if (archive_write_open_filename(a, tmpPath.fileSystemRepresentation) != ARCHIVE_OK) {
        error = FAError(FAErrorIO, @"Could not create the archive (%s).", archive_error_string(a) ?: "unknown error");
    }
    __block FAThrottle throttle = {0};
    __block double done = 0;
    __block unsigned long long sinceSpaceCheck = 0;
    __block NSUInteger count = 0;
    char *buffer = malloc(kFABlock);
    if (!error) FAWalk(items, job, ^BOOL(const char *abs, NSString *rel, const struct stat *st) {
        NSString *display = rel.lastPathComponent;
        if (++count % kFASpaceCheckEntries == 0 && FAFreeBytes(outDir) < FAFreeSpaceReserve) { error = FANoSpaceError(); return NO; }
        if (!S_ISREG(st->st_mode) && !S_ISDIR(st->st_mode) && !S_ISLNK(st->st_mode)) return YES;
        struct archive_entry *e = archive_entry_new();
        archive_entry_copy_stat(e, st);
        archive_entry_set_uid(e, 0); archive_entry_set_gid(e, 0);
        archive_entry_set_perm(e, S_ISDIR(st->st_mode) ? 0755 : ((st->st_mode & 0111) ? 0755 : 0644));
        archive_entry_set_pathname_utf8(e, rel.precomposedStringWithCanonicalMapping.UTF8String);
        int fd = -1;
        if (S_ISLNK(st->st_mode)) {
            char target[PATH_MAX];
            ssize_t n = readlink(abs, target, sizeof(target) - 1);
            if (n < 0) { archive_entry_free(e); return YES; }
            target[n] = 0;
            archive_entry_set_symlink_utf8(e, target);
            archive_entry_set_size(e, 0);
        } else if (S_ISREG(st->st_mode)) {
            fd = open(abs, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
            if (fd < 0) {
                error = FAError(FAErrorIO, @"Could not read “%@” (%@).", display, FAPosixText(errno));
                archive_entry_free(e);
                return NO;
            }
        } else {
            archive_entry_set_size(e, 0);
        }
        if (archive_write_header(a, e) < ARCHIVE_WARN) {
            error = FAError(FAErrorIO, @"Could not add “%@” (%s).", display, archive_error_string(a) ?: "unknown error");
        }
        while (!error && fd >= 0) {
            ssize_t n = read(fd, buffer, kFABlock);
            if (n < 0 && errno == EINTR) continue;
            if (n < 0) { error = FAError(FAErrorIO, @"Could not read “%@” (%@).", display, FAPosixText(errno)); break; }
            if (n == 0) break;
            if (archive_write_data(a, buffer, (size_t)n) < 0) {
                error = FAError(FAErrorIO, @"Could not write the archive (%s).", archive_error_string(a) ?: "unknown error");
                break;
            }
            done += n;
            sinceSpaceCheck += n;
            if (sinceSpaceCheck >= kFASpaceCheckBytes) {
                sinceSpaceCheck = 0;
                if (FAFreeBytes(outDir) < FAFreeSpaceReserve) { error = FANoSpaceError(); break; }
            }
            FAReport(job, &throttle, done / total, display, NO);
            if (job.cancelled) break;
        }
        if (fd >= 0) close(fd);
        archive_entry_free(e);
        done += kFAEntryWeight;
        FAReport(job, &throttle, done / total, display, NO);
        return error == nil;
    });
    if (!error && job.cancelled) error = FAError(FAErrorCancelled, @"Cancelled.");
    free(buffer);
    if (!error && archive_write_close(a) != ARCHIVE_OK) {
        error = FAError(FAErrorIO, @"Could not finish the archive (%s).", archive_error_string(a) ?: "unknown error");
    }
    // Otherwise free() would still finish the archive, which for 7z means compressing and copying
    // everything written so far: seconds after a Cancel, too long when iOS is ending the job.
    if (error) archive_write_fail(a);
    archive_write_free(a);

    if (!error) {
        finalName = [self uniqueName:finalName inDirectories:nameDirs];
        NSString *dest = [outDir stringByAppendingPathComponent:finalName];
        chmod(tmpPath.fileSystemRepresentation, 0644);
        if (rename(tmpPath.fileSystemRepresentation, dest.fileSystemRepresentation) == 0) {
            FAReport(job, &throttle, 1, nil, YES);
            return [NSURL fileURLWithPath:dest];
        }
        error = FAError(FAErrorIO, @"Could not create “%@” (%@).", finalName, FAPosixText(errno));
    }
    unlink(tmpPath.fileSystemRepresentation);
    if (outError) *outError = error;
    return nil;
}

@end
