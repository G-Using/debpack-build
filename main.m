/* debpack — 一键导出已安装 deb 与插件配置 plist
 * rootless (Dopamine / RootHide) + rootful 通用
 *
 * 用法:
 *   debpack list
 *   debpack export --all [--out DIR] [--force] [--no-prefs]
 *   debpack export <pkgid> <pkgid...>
 */

#import <Foundation/Foundation.h>

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>

extern char **environ;

static NSString *gAdminDir = nil;

/* ---------------- 前向声明 ---------------- */
static void Print(NSString *fmt, ...);
static BOOL FileExistsAt(NSString *p);
static BOOL IsDirAt(NSString *p);
static BOOL MkdirP(NSString *p);
static NSString *FindAdminDir(void);
static NSString *JBPrefix(void);
static NSString *FindTool(NSString *name);
static int RunTool(NSString *tool, NSArray<NSString *> *args, NSString *capture, NSString **outText);
static NSString *SafeName(NSString *s);
static BOOL CopyRegularFile(NSString *src, NSString *dst, struct stat *st);

/* ---------------- 基础工具 ---------------- */

static void Print(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fputs([[s stringByAppendingString:@"\n"] UTF8String], stdout);
    fflush(stdout);
}

static BOOL FileExistsAt(NSString *p) {
    struct stat st;
    return (lstat([p fileSystemRepresentation], &st) == 0);
}

static BOOL IsDirAt(NSString *p) {
    struct stat st;
    if (lstat([p fileSystemRepresentation], &st) != 0) return NO;
    return S_ISDIR(st.st_mode);
}

static BOOL MkdirP(NSString *p) {
    if (IsDirAt(p)) return YES;
    NSString *parent = [p stringByDeletingLastPathComponent];
    if (parent.length > 0 && ![parent isEqualToString:@"/"] && ![parent isEqualToString:p]) {
        if (!MkdirP(parent)) return NO;
    }
    return (mkdir([p fileSystemRepresentation], 0755) == 0 || IsDirAt(p));
}

static BOOL CopyRegularFile(NSString *src, NSString *dst, struct stat *st) {
    NSData *d = [NSData dataWithContentsOfFile:src];
    if (!d) return NO;
    if (![d writeToFile:dst atomically:NO]) return NO;
    chmod([dst fileSystemRepresentation], st ? (st->st_mode & 07777) : 0644);
    return YES;
}

static NSString *SafeName(NSString *s) {
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/:\\ \t"];
    return [[s componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
}

static int RunTool(NSString *tool, NSArray<NSString *> *args, NSString *capture, NSString **outText) {
    if (!FileExistsAt(tool)) return -1;
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    if (capture) {
        posix_spawn_file_actions_addopen(&fa, 1, [capture fileSystemRepresentation],
                                         O_WRONLY | O_CREAT | O_TRUNC, 0644);
        posix_spawn_file_actions_adddup2(&fa, 1, 2);
    } else {
        posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
        posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
    }
    const char *argv[40];
    int i = 0;
    argv[i++] = [tool fileSystemRepresentation];
    for (NSString *a in args) {
        if (i >= 39) break;
        argv[i++] = [a fileSystemRepresentation];
    }
    argv[i] = NULL;

    pid_t pid = 0;
    int rc = posix_spawn(&pid, [tool fileSystemRepresentation], &fa, NULL,
                         (char *const *)argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    if (rc != 0) return rc;

    int status = 0;
    waitpid(pid, &status, 0);

    if (outText) {
        *outText = @"";
        if (capture) {
            NSString *t = [NSString stringWithContentsOfFile:capture
                                                    encoding:NSUTF8StringEncoding
                                                       error:nil];
            if (t) *outText = t;
        }
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

static NSString *FindAdminDir(void) {
    NSArray<NSString *> *cands = @[
        @"/var/jb/var/lib/dpkg",
        @"/var/lib/dpkg",
        @"/var/jb/Library/dpkg",
        @"/usr/local/lib/dpkg",
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *c in cands) {
        if ([fm fileExistsAtPath:[c stringByAppendingPathComponent:@"status"]]) return c;
    }
    return nil;
}

static NSString *JBPrefix(void) {
    if (IsDirAt(@"/var/jb")) return @"/var/jb";
    if (IsDirAt(@"/.bootstrapped_electra")) return @"/bootstrap";
    return @"";
}

static NSString *FindTool(NSString *name) {
    NSString *jb = JBPrefix();
    NSMutableArray<NSString *> *cands = [NSMutableArray array];
    if (jb.length > 0) {
        [cands addObject:[NSString stringWithFormat:@"%@/usr/bin/%@", jb, name]];
        [cands addObject:[NSString stringWithFormat:@"%@/usr/local/bin/%@", jb, name]];
        [cands addObject:[NSString stringWithFormat:@"%@/bin/%@", jb, name]];
    }
    [cands addObject:[NSString stringWithFormat:@"/usr/bin/%@", name]];
    [cands addObject:[NSString stringWithFormat:@"/usr/local/bin/%@", name]];
    [cands addObject:[NSString stringWithFormat:@"/bin/%@", name]];
    for (NSString *c in cands) {
        if (FileExistsAt(c)) return c;
    }
    return nil;
}

/* ---------------- 包模型 ---------------- */

@interface DPPkg : NSObject
@property (nonatomic, strong) NSString *pkgId;
@property (nonatomic, strong) NSString *displayName;
@property (nonatomic, strong) NSString *version;
@property (nonatomic, strong) NSString *arch;
@property (nonatomic, strong) NSString *section;
@property (nonatomic, strong) NSString *author;
@property (nonatomic, assign) long long installedSize;
@property (nonatomic, assign) BOOL essential;
@property (nonatomic, strong) NSArray<NSString *> *files;
@property (nonatomic, strong) NSArray<NSString *> *conffiles;
@property (nonatomic, strong) NSMutableArray<NSString *> *controlLines;
@property (nonatomic, strong) NSArray<NSString *> *prefsDomains;
@end

@implementation DPPkg
- (instancetype)init {
    if ((self = [super init])) {
        _pkgId = @"";
        _displayName = @"";
        _version = @"";
        _arch = @"";
        _section = @"";
        _author = @"";
        _installedSize = 0;
        _essential = NO;
        _files = @[];
        _conffiles = @[];
        _controlLines = [NSMutableArray array];
        _prefsDomains = @[];
    }
    return self;
}
@end

/* ---------------- 解析 dpkg status ---------------- */

static NSString *Trim(NSString *s) {
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSArray<DPPkg *> *ParseStatus(NSString *statusPath) {
    NSString *raw = [NSString stringWithContentsOfFile:statusPath
                                             encoding:NSUTF8StringEncoding
                                                error:nil];
    if (!raw) return nil;

    NSMutableArray<DPPkg *> *result = [NSMutableArray array];
    NSArray<NSString *> *stanzas = [raw componentsSeparatedByString:@"\n\n"];

    for (NSString *stanza in stanzas) {
        if (Trim(stanza).length == 0) continue;

        NSMutableArray<NSString *> *keys = [NSMutableArray array];
        NSMutableDictionary<NSString *, NSString *> *vals = [NSMutableDictionary dictionary];
        NSString *curKey = nil;
        NSMutableString *curVal = nil;

        for (NSString *rawLine in [stanza componentsSeparatedByString:@"\n"]) {
            if (rawLine.length == 0) continue;
            unichar c = [rawLine characterAtIndex:0];
            if (c == ' ' || c == '\t') {
                if (curVal) [curVal appendFormat:@"\n%@", [rawLine substringFromIndex:1]];
                continue;
            }
            NSRange r = [rawLine rangeOfString:@":"];
            if (r.location == NSNotFound) continue;
            if (curKey && curVal) {
                [keys addObject:curKey];
                vals[curKey] = [NSString stringWithString:curVal];
            }
            curKey = [rawLine substringToIndex:r.location];
            curVal = [NSMutableString stringWithString:Trim([rawLine substringFromIndex:r.location + 1])];
        }
        if (curKey && curVal) {
            [keys addObject:curKey];
            vals[curKey] = [NSString stringWithString:curVal];
        }

        NSString *status = vals[@"Status"] ?: @"";
        if ([status rangeOfString:@"installed"].location == NSNotFound) continue;
        if ([status rangeOfString:@"deinstall"].location != NSNotFound) continue;

        NSString *pid = vals[@"Package"];
        if (!pid || pid.length == 0) continue;

        DPPkg *p = [[DPPkg alloc] init];
        p.pkgId = pid;
        p.displayName = (vals[@"Name"] && vals[@"Name"].length > 0) ? vals[@"Name"] : pid;
        p.version = vals[@"Version"] ?: @"";
        p.arch = vals[@"Architecture"] ?: @"iphoneos-arm";
        p.section = vals[@"Section"] ?: @"";
        p.author = vals[@"Author"] ?: vals[@"Maintainer"] ?: @"";
        p.essential = [vals[@"Essential"] isEqualToString:@"yes"];
        if (vals[@"Installed-Size"]) p.installedSize = [vals[@"Installed-Size"] longLongValue];

        for (NSString *k in keys) {
            if ([k isEqualToString:@"Status"]) continue;
            if ([k isEqualToString:@"Conffiles"]) continue;
            [p.controlLines addObject:[NSString stringWithFormat:@"%@: %@", k, vals[k]]];
        }
        NSMutableArray<NSString *> *cf = [NSMutableArray array];
        NSString *conffiles = vals[@"Conffiles"];
        if (conffiles.length > 0) {
            for (NSString *line in [conffiles componentsSeparatedByString:@"\n"]) {
                NSString *t = Trim(line);
                if (t.length == 0) continue;
                NSArray<NSString *> *parts = [t componentsSeparatedByString:@" "];
                NSString *last = parts.lastObject;
                if (last.length > 0) [cf addObject:last];
            }
        }
        p.conffiles = cf;
        [result addObject:p];
    }
    return result;
}

/* ---------------- 风险包判定 ---------------- */

static BOOL IsRisky(DPPkg *p) {
    if (p.essential) return YES;
    static NSArray<NSString *> *exact = nil;
    if (!exact) {
        exact = @[
            @"cydia", @"mobilesubstrate", @"com.saurik.substrate.safemode",
            @"substitute", @"com.ex.substitute", @"libsubstitute", @"libsubstrate",
            @"ellekit", @"libellekit", @"org.coolstar.substitute",
            @"dpkg", @"dpkg-dev", @"apt", @"apt7", @"apt-key", @"apt1.4", @"apt0",
            @"bash", @"coreutils", @"coreutils-bin", @"debianutils", @"diffutils",
            @"diskdev-cmds", @"file-cmds", @"findutils", @"gpgv", @"grep", @"gzip",
            @"inetutils", @"ldid", @"network-cmds", @"openssh", @"openssh-client",
            @"openssh-server", @"openssl", @"profile.d", @"sed", @"shell-cmds",
            @"system-cmds", @"tar", @"unzip", @"zip", @"zstd", @"xz", @"ca-certificates",
            @"berkeleydb", @"libapt", @"libapt-pkg", @"libapt-pkg6.0", @"libbz2",
            @"libcom_err", @"libcrypt2", @"libffi", @"libgcrypt", @"libgpg-error",
            @"libidn2", @"liblzma", @"libncursesw6", @"libpcre", @"libpcre2",
            @"libreadline", @"libssl", @"libssl3", @"libunistring", @"libzstd",
            @"ncurses", @"ncurses5-libs", @"ncurses6", @"newt", @"p11-kit",
            @"readline", @"system", @"uikittools", @"util-linux", @"wget",
            @"firmware", @"firmware-sbin", @"essential", @"libplist", @"libtinfo6",
        ];
    }
    if ([exact containsObject:p.pkgId]) return YES;
    NSArray<NSString *> *prefixes = @[@"firmware", @"org.swift.", @"apt", @"dpkg",
                                      @"cydia", @"mobilesubstrate", @"libapt",
                                      @"com.opa334.", @"com.saurik."];
    for (NSString *pre in prefixes) {
        if ([p.pkgId hasPrefix:pre]) return YES;
    }
    return NO;
}

/* ---------------- 文件列表 / 配置域名 ---------------- */

static NSArray<NSString *> *FileListFor(NSString *adminDir, NSString *pkgId) {
    NSString *p = [NSString stringWithFormat:@"%@/info/%@.list", adminDir, pkgId];
    NSString *raw = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
    if (!raw) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *line in [raw componentsSeparatedByString:@"\n"]) {
        NSString *t = Trim(line);
        if (t.length > 0) [out addObject:t];
    }
    return out;
}

static NSString *ResolveReal(NSString *logical, NSString *prefix) {
    if (FileExistsAt(logical)) return logical;
    if (prefix.length > 0) {
        NSString *p2 = [prefix stringByAppendingPathComponent:logical];
        if (FileExistsAt(p2)) return p2;
    }
    NSString *p3 = [@"/var/jb" stringByAppendingPathComponent:logical];
    if (FileExistsAt(p3)) return p3;
    return nil;
}

static NSString *PrefsRoot(void) {
    NSArray<NSString *> *cands = @[@"/var/mobile/Library/Preferences",
                                   @"/var/jb/var/mobile/Library/Preferences"];
    for (NSString *c in cands) {
        if (IsDirAt(c)) return c;
    }
    return @"/var/mobile/Library/Preferences";
}

static NSArray<NSString *> *DomainsForPackage(DPPkg *p, NSString *prefix) {
    NSMutableArray<NSString *> *doms = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    for (NSString *f in p.files) {
        if ([f rangeOfString:@"/Library/PreferenceBundles/"].location == NSNotFound) continue;
        if (![f hasSuffix:@".bundle/Info.plist"]) continue;
        NSString *real = ResolveReal(f, prefix);
        if (!real) continue;
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:real];
        NSString *bid = d[@"CFBundleIdentifier"];
        if (bid.length > 0 && ![seen containsObject:bid]) {
            [seen addObject:bid];
            [doms addObject:bid];
        }
    }
    if (![seen containsObject:p.pkgId]) {
        [seen addObject:p.pkgId];
        [doms addObject:p.pkgId];
    }
    return doms;
}

/* ---------------- deb 导出 ---------------- */

static BOOL TryCachedDeb(DPPkg *p, NSString *prefix, NSString *debDir, NSString **outPath) {
    NSArray<NSString *> *dirs = @[
        [NSString stringWithFormat:@"%@/var/cache/apt/archives", prefix],
        [NSString stringWithFormat:@"%@/var/cache/apt/archives/partial", prefix],
        @"/var/cache/apt/archives",
        @"/var/mobile/Library/Caches/com.danielplatonov.sileo/Archives",
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *want = [NSString stringWithFormat:@"%@_", p.pkgId];
    for (NSString *d in dirs) {
        NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:d error:nil];
        if (!items) continue;
        for (NSString *it in items) {
            if (![it hasPrefix:want]) continue;
            if (![it hasSuffix:@".deb"]) continue;
            NSString *src = [d stringByAppendingPathComponent:it];
            NSString *dst = [debDir stringByAppendingPathComponent:
                             [NSString stringWithFormat:@"%@.deb", SafeName(p.pkgId)]];
            NSError *e = nil;
            [[NSFileManager defaultManager] removeItemAtPath:dst error:nil];
            if ([fm copyItemAtPath:src toPath:dst error:&e]) {
                if (outPath) *outPath = dst;
                return YES;
            }
        }
    }
    return NO;
}

static BOOL Materialize(DPPkg *p, NSString *root, NSString *prefix, NSUInteger *done) {
    NSFileManager *fm = [NSFileManager defaultManager];
    static NSSet<NSString *> *skipDirs = nil;
    if (!skipDirs) {
        skipDirs = [NSSet setWithObjects:@"/.", @"/", @"/usr", @"/var", @"/etc", @"/bin",
                    @"/sbin", @"/Library", @"/System", @"/private", @"/var/jb",
                    @"/var/jb/usr", @"/var/jb/etc", @"/var/jb/bin", @"/var/jb/sbin",
                    @"/var/jb/Library", @"/var/jb/var", @"/Library/MobileSubstrate",
                    @"/Library/PreferenceBundles", @"/usr/lib", @"/usr/bin", @"/usr/sbin",
                    @"/var/jb/usr/lib", @"/var/jb/usr/bin", @"/var/jb/usr/sbin",
                    @"/var/jb/Library/MobileSubstrate", @"/var/jb/Library/PreferenceBundles",
                    nil];
    }
    NSUInteger n = 0;
    for (NSString *logical in p.files) {
        if ([skipDirs containsObject:logical]) continue;
        NSString *real = ResolveReal(logical, prefix);
        if (!real) continue;

        struct stat st;
        if (lstat([real fileSystemRepresentation], &st) != 0) continue;

        NSString *dst = [root stringByAppendingPathComponent:logical];
        NSString *parent = [dst stringByDeletingLastPathComponent];
        if (!IsDirAt(parent)) MkdirP(parent);

        const char *rd = [dst fileSystemRepresentation];
        if (S_ISDIR(st.st_mode)) {
            mkdir(rd, st.st_mode & 07777);
            chown(rd, 0, 0);
        } else if (S_ISLNK(st.st_mode)) {
            char buf[4096];
            ssize_t len = readlink([real fileSystemRepresentation], buf, sizeof(buf) - 1);
            if (len > 0) {
                buf[len] = 0;
                unlink(rd);
                if (symlink(buf, rd) == 0) lchown(rd, 0, 0);
            }
        } else if (S_ISREG(st.st_mode)) {
            unlink(rd);
            if (link([real fileSystemRepresentation], rd) != 0) {
                if (!CopyRegularFile(real, dst, &st)) continue;
            }
            chown(rd, 0, 0);
            chmod(rd, st.st_mode & 07777);
        } else {
            continue;
        }
        n++;
    }
    if (done) *done = n;
    return n > 0;
}

static BOOL BuildDeb(DPPkg *p, NSString *debDir, NSString *tmpRoot, NSString *prefix,
                     NSString *dpkgDeb, NSString **outPath, NSString **err) {
    NSString *safe = SafeName(p.pkgId);
    NSString *stage = [tmpRoot stringByAppendingPathComponent:safe];
    NSString *root = [stage stringByAppendingPathComponent:@"root"];
    NSString *debian = [root stringByAppendingPathComponent:@"DEBIAN"];

    [[NSFileManager defaultManager] removeItemAtPath:stage error:nil];
    if (!MkdirP(debian)) {
        if (err) *err = @"无法创建暂存目录";
        return NO;
    }
    chmod([debian fileSystemRepresentation], 0755);

    NSMutableString *ctl = [NSMutableString string];
    BOOL hasPackage = NO, hasVersion = NO, hasArch = NO, hasMaintainer = NO, hasDesc = NO;
    for (NSString *line in p.controlLines) {
        [ctl appendFormat:@"%@\n", line];
        if ([line hasPrefix:@"Package:"]) hasPackage = YES;
        if ([line hasPrefix:@"Version:"]) hasVersion = YES;
        if ([line hasPrefix:@"Architecture:"]) hasArch = YES;
        if ([line hasPrefix:@"Maintainer:"]) hasMaintainer = YES;
        if ([line hasPrefix:@"Description:"]) hasDesc = YES;
    }
    if (!hasPackage) [ctl appendFormat:@"Package: %@\n", p.pkgId];
    if (!hasVersion) [ctl appendFormat:@"Version: %@\n", p.version.length ? p.version : @"0"];
    if (!hasArch) [ctl appendString:@"Architecture: iphoneos-arm\n"];
    if (!hasMaintainer) [ctl appendString:@"Maintainer: debpack\n"];
    if (!hasDesc) [ctl appendFormat:@"Description: %@\n", p.displayName];

    NSError *werr = nil;
    if (![ctl writeToFile:[debian stringByAppendingPathComponent:@"control"]
               atomically:YES encoding:NSUTF8StringEncoding error:&werr]) {
        if (err) *err = @"写入 control 失败";
        return NO;
    }
    chmod([[debian stringByAppendingPathComponent:@"control"] fileSystemRepresentation], 0644);

    if (p.conffiles.count > 0) {
        NSString *cf = [[p.conffiles componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
        [cf writeToFile:[debian stringByAppendingPathComponent:@"conffiles"]
             atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }

    NSArray<NSString *> *scripts = @[@"preinst", @"postinst", @"prerm", @"postrm"];
    for (NSString *s in scripts) {
        NSString *src = nil;
        NSString *cand = nil;
        if (gAdminDir.length > 0) {
            cand = [NSString stringWithFormat:@"%@/info/%@.%@", gAdminDir, p.pkgId, s];
            if (FileExistsAt(cand)) src = cand;
        }
        if (!src) {
            cand = [NSString stringWithFormat:@"/var/jb/var/lib/dpkg/info/%@.%@", p.pkgId, s];
            if (FileExistsAt(cand)) src = cand;
        }
        if (!src) {
            cand = [NSString stringWithFormat:@"/var/lib/dpkg/info/%@.%@", p.pkgId, s];
            if (FileExistsAt(cand)) src = cand;
        }
        if (src) {
            NSString *dst = [debian stringByAppendingPathComponent:s];
            [[NSFileManager defaultManager] copyItemAtPath:src toPath:dst error:nil];
            chmod([dst fileSystemRepresentation], 0755);
        }
    }

    NSUInteger count = 0;
    if (!Materialize(p, root, prefix, &count)) {
        [[NSFileManager defaultManager] removeItemAtPath:stage error:nil];
        if (err) *err = @"没有可打包的文件（可能已损坏或是虚拟包）";
        return NO;
    }

    NSString *outDeb = [debDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.deb", safe]];
    [[NSFileManager defaultManager] removeItemAtPath:outDeb error:nil];

    NSString *cap = [tmpRoot stringByAppendingPathComponent:@"dpkg-deb.log"];
    NSString *log = @"";
    int rc = RunTool(dpkgDeb, @[@"--root-owner-group", @"-b", root, outDeb], cap, &log);
    if (rc != 0) {
        rc = RunTool(dpkgDeb, @[@"-b", root, outDeb], cap, &log);
    }
    [[NSFileManager defaultManager] removeItemAtPath:stage error:nil];

    if (rc != 0 || !FileExistsAt(outDeb)) {
        if (err) *err = [NSString stringWithFormat:@"dpkg-deb 失败(%d): %@", rc,
                         [log stringByReplacingOccurrencesOfString:@"\n" withString:@" "]];
        return NO;
    }
    if (outPath) *outPath = outDeb;
    return YES;
}

/* ---------------- 递归 chown ---------------- */

static void ChownRecursive(NSString *path, uid_t u, gid_t g) {
    chown([path fileSystemRepresentation], u, g);
    DIR *d = opendir([path fileSystemRepresentation]);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
        NSString *child = [path stringByAppendingPathComponent:[NSString stringWithUTF8String:e->d_name]];
        chown([child fileSystemRepresentation], u, g);
        if (IsDirAt(child)) ChownRecursive(child, u, g);
    }
    closedir(d);
}

/* ---------------- 主流程 ---------------- */

static void PrintUsage(void) {
    Print(@"debpack — 已安装 deb / 插件配置一键导出");
    Print(@"");
    Print(@"  debpack list                      列出所有已安装插件（中文名 + id + 版本）");
    Print(@"  debpack export --all              导出全部");
    Print(@"  debpack export <id> [id...]       只导出指定的包");
    Print(@"  debpack export --all --force      连同系统底层包一起导出（不建议）");
    Print(@"  debpack export --all --no-prefs   不导出配置 plist");
    Print(@"  debpack export --all --out DIR    指定输出目录");
    Print(@"");
    Print(@"默认输出: /var/mobile/Documents/DebBackup/<时间戳>/");
}

static void DoList(NSArray<DPPkg *> *pkgs, NSString *prefix) {
    NSMutableArray<DPPkg *> *sorted = [pkgs mutableCopy];
    [sorted sortUsingComparator:^NSComparisonResult(DPPkg *a, DPPkg *b) {
        NSComparisonResult r = [a.displayName compare:b.displayName options:NSCaseInsensitiveSearch];
        if (r != NSOrderedSame) return r;
        return [a.pkgId compare:b.pkgId];
    }];
    Print(@"共 %lu 个已安装包", (unsigned long)sorted.count);
    Print(@"名字\t标识\t版本\t配置");
    Print(@"----\t----\t----\t----");
    NSUInteger idx = 0;
    for (DPPkg *p in sorted) {
        idx++;
        p.prefsDomains = DomainsForPackage(p, prefix);
        NSString *prefsRoot = PrefsRoot();
        BOOL hasPrefs = NO;
        for (NSString *d in p.prefsDomains) {
            if (FileExistsAt([NSString stringWithFormat:@"%@/%@.plist", prefsRoot, d])) {
                hasPrefs = YES;
                break;
            }
        }
        NSString *mark = hasPrefs ? @"有" : @"-";
        if (IsRisky(p)) mark = [mark stringByAppendingString:@"(系统)"];
        Print(@"%-3lu %@\t%@\t%@\t%@", (unsigned long)idx, p.displayName, p.pkgId, p.version, mark);
    }
}

static BOOL DoExport(NSArray<DPPkg *> *pkgs, NSString *prefix, NSString *outDir,
                     BOOL exportPrefs, BOOL force) {
    NSString *dpkgDeb = FindTool(@"dpkg-deb");
    if (!dpkgDeb) {
        Print(@"[错误] 找不到 dpkg-deb，无法打包");
        return NO;
    }

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd-HHmm";
    NSString *stamp = [fmt stringFromDate:[NSDate date]];
    if (outDir.length == 0) {
        outDir = [NSString stringWithFormat:@"/var/mobile/Documents/DebBackup/%@", stamp];
    }
    NSString *debDir = [outDir stringByAppendingPathComponent:@"debs"];
    NSString *prefsDir = [outDir stringByAppendingPathComponent:@"prefs"];
    NSString *tmpRoot = [NSString stringWithFormat:@"%@/tmp/debpack-%@", prefix.length ? prefix : @"/var/jb", stamp];

    if (!MkdirP(debDir)) { Print(@"[错误] 无法创建输出目录 %@", debDir); return NO; }
    MkdirP(prefsDir);
    MkdirP(tmpRoot);

    NSString *prefsRoot = PrefsRoot();
    NSFileManager *fm = [NSFileManager defaultManager];

    NSMutableArray<NSMutableDictionary *> *manifest = [NSMutableArray array];
    NSMutableString *txt = [NSMutableString string];
    [txt appendString:@"名字\t标识\t版本\t配置域\tdeb文件\n"];

    NSUInteger okDeb = 0, failDeb = 0, skipRisky = 0, okPrefs = 0, cached = 0;
    NSUInteger total = pkgs.count;
    NSUInteger i = 0;

    for (DPPkg *p in pkgs) {
        i++;
        p.prefsDomains = DomainsForPackage(p, prefix);

        if (IsRisky(p) && !force) {
            skipRisky++;
            continue;
        }

        BOOL fromCache = NO;
        NSString *debPath = nil;
        NSString *err = nil;
        BOOL ok = NO;

        if (TryCachedDeb(p, prefix, debDir, &debPath)) {
            ok = YES;
            fromCache = YES;
            cached++;
        } else {
            ok = BuildDeb(p, debDir, tmpRoot, prefix, dpkgDeb, &debPath, &err);
        }

        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        m[@"Package"] = p.pkgId;
        m[@"Name"] = p.displayName;
        m[@"Version"] = p.version;
        m[@"Section"] = p.section;
        m[@"Architecture"] = p.arch;
        m[@"InstalledSize"] = @(p.installedSize);

        NSMutableArray<NSString *> *exportedPrefs = [NSMutableArray array];
        if (exportPrefs) {
            for (NSString *d in p.prefsDomains) {
                NSString *src = [NSString stringWithFormat:@"%@/%@.plist", prefsRoot, d];
                if (!FileExistsAt(src)) continue;
                NSString *dst = [prefsDir stringByAppendingPathComponent:
                                 [NSString stringWithFormat:@"%@.plist", SafeName(d)]];
                [fm removeItemAtPath:dst error:nil];
                NSError *ce = nil;
                if ([fm copyItemAtPath:src toPath:dst error:&ce]) {
                    [exportedPrefs addObject:d];
                    okPrefs++;
                }
            }
        }
        m[@"PrefsDomains"] = exportedPrefs;

        if (ok && debPath) {
            okDeb++;
            m[@"DebFile"] = [@"debs" stringByAppendingPathComponent:[debPath lastPathComponent]];
            m[@"FromCache"] = @(fromCache);
            unsigned long long sz = [[fm attributesOfItemAtPath:debPath error:nil] fileSize];
            m[@"DebSize"] = @(sz);
            Print(@"[%lu/%lu] %@  %@  %@", (unsigned long)i, (unsigned long)total,
                  p.displayName, fromCache ? @"(缓存)" : @"(重建)",
                  sz > 1048576 ? [NSString stringWithFormat:@"%.1f MB", sz / 1048576.0]
                               : [NSString stringWithFormat:@"%llu KB", sz / 1024]);
        } else {
            failDeb++;
            m[@"DebFile"] = @"";
            m[@"Error"] = err ?: @"未知错误";
            Print(@"[%lu/%lu] %@  失败: %@", (unsigned long)i, (unsigned long)total,
                  p.displayName, err ?: @"未知错误");
        }

        [manifest addObject:m];
        [txt appendFormat:@"%@\t%@\t%@\t%@\t%@\n", p.displayName, p.pkgId, p.version,
              [exportedPrefs componentsJoinedByString:@","], m[@"DebFile"]];
    }

    [manifest writeToFile:[outDir stringByAppendingPathComponent:@"manifest.plist"] atomically:YES];
    [txt writeToFile:[outDir stringByAppendingPathComponent:@"Packages.txt"]
          atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSString *script = @"#!/bin/bash\n"
    @"# debpack 自动生成的恢复脚本\n"
    @"# 用法: 用 Filza / NewTerm 以 root 执行  sh restore.sh\n"
    @"DIR=\"$(cd \"$(dirname \"$0\")\" && pwd)\"\n"
    @"echo \"==> 安装 deb\"\n"
    @"for f in \"$DIR\"/debs/*.deb; do\n"
    @"  echo \"  $(basename \"$f\")\"\n"
    @"  dpkg -i \"$f\"\n"
    @"done\n"
    @"echo \"==> 恢复配置 plist\"\n"
    @"for f in \"$DIR\"/prefs/*.plist; do\n"
    @"  n=\"$(basename \"$f\")\"\n"
    @"  cp -p \"$f\" \"/var/mobile/Library/Preferences/$n\"\n"
    @"  chown mobile:mobile \"/var/mobile/Library/Preferences/$n\"\n"
    @"done\n"
    @"echo \"==> 让系统重新读取配置\"\n"
    @"killall cfprefsd 2>/dev/null\n"
    @"echo \"完成。建议注销 SpringBoard 让插件生效。\"\n";
    [script writeToFile:[outDir stringByAppendingPathComponent:@"restore.sh"]
             atomically:YES encoding:NSUTF8StringEncoding error:nil];
    chmod([[outDir stringByAppendingPathComponent:@"restore.sh"] fileSystemRepresentation], 0755);

    ChownRecursive(outDir, 501, 501);
    [[NSFileManager defaultManager] removeItemAtPath:tmpRoot error:nil];

    Print(@"");
    Print(@"===== 完成 =====");
    Print(@"输出目录: %@", outDir);
    Print(@"deb 成功 %lu（其中缓存直取 %lu），失败 %lu，跳过系统包 %lu",
          (unsigned long)okDeb, (unsigned long)cached, (unsigned long)failDeb,
          (unsigned long)skipRisky);
    Print(@"配置 plist 导出 %lu 个", (unsigned long)okPrefs);
    return YES;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (geteuid() != 0) {
            Print(@"[错误] debpack 需要 root 权限，请用 sudo 或在 root shell 下运行");
            return 1;
        }
        if (argc < 2) {
            PrintUsage();
            return 0;
        }

        NSString *cmd = [NSString stringWithUTF8String:argv[1]];
        NSString *adminDir = FindAdminDir();
        if (!adminDir) {
            Print(@"[错误] 找不到 dpkg 数据库（/var/jb/var/lib/dpkg）");
            return 1;
        }
        gAdminDir = adminDir;
        NSString *prefix = JBPrefix();
        NSArray<DPPkg *> *pkgs = ParseStatus([adminDir stringByAppendingPathComponent:@"status"]);
        if (!pkgs) {
            Print(@"[错误] 无法解析 %@/status", adminDir);
            return 1;
        }
        for (DPPkg *p in pkgs) {
            p.files = FileListFor(adminDir, p.pkgId);
        }

        Print(@"[信息] dpkg 数据库: %@", adminDir);
        Print(@"[信息] 越狱前缀: %@", prefix.length ? prefix : @"(rootful)");

        if ([cmd isEqualToString:@"list"]) {
            DoList(pkgs, prefix);
            return 0;
        }

        if ([cmd isEqualToString:@"export"]) {
            NSMutableArray<NSString *> *ids = [NSMutableArray array];
            BOOL all = NO, force = NO, noPrefs = NO;
            NSString *outDir = nil;
            for (int i = 2; i < argc; i++) {
                NSString *a = [NSString stringWithUTF8String:argv[i]];
                if ([a isEqualToString:@"--all"]) all = YES;
                else if ([a isEqualToString:@"--force"]) force = YES;
                else if ([a isEqualToString:@"--no-prefs"]) noPrefs = YES;
                else if ([a isEqualToString:@"--out"]) {
                    if (i + 1 < argc) outDir = [NSString stringWithUTF8String:argv[++i]];
                } else if ([a hasPrefix:@"-"]) {
                    /* 忽略未知开关 */
                } else {
                    [ids addObject:a];
                }
            }
            NSArray<DPPkg *> *targets = nil;
            if (all) {
                targets = pkgs;
            } else if (ids.count > 0) {
                NSMutableArray<DPPkg *> *sel = [NSMutableArray array];
                for (NSString *ident in ids) {
                    for (DPPkg *p in pkgs) {
                        if ([p.pkgId isEqualToString:ident]) [sel addObject:p];
                    }
                }
                targets = sel;
            } else {
                PrintUsage();
                return 1;
            }
            BOOL ok = DoExport(targets, prefix, outDir, !noPrefs, force);
            return ok ? 0 : 1;
        }

        PrintUsage();
        return 0;
    }
}
