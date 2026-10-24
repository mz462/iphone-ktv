// MRProbe: KTV on top of Apple Music, TV over HDMI.
//  - Music plays the song (public systemMusicPlayer); this app follows whatever is playing.
//  - Phone: KTV console. 原唱/伴唱 toggle and accompaniment vocal level go to Music via
//    MediaRemote VocalsControl (private); 重唱 / 暂停 / 切歌 / seek use the public player.
//    The vocal controls hide for songs the catalog lists without lyrics, which Music cannot reduce.
//  - Lyrics: LRCLIB timed lyrics, re-fetched when the song changes. Long lines are split in two.
//  - TV: external-display scene with two alternating KTV lines (sparks at the wipe edge, lines fly in
//    and out), song intro card, progress bar, album-art backdrop with glow blobs and stage rays.
//    The app cannot hear Music, so the background pulses on lyric line starts instead of the beat.
//  - Party: friends on the same Wi-Fi scan the QR code on the TV (http://<phone>:8080, page in party.html)
//    to search Apple Music and queue songs, send emoji / 弹幕 / fireworks to the TV, and turn their phone
//    into a cheer light that flashes with the lyric lines. Works only while this app is in the foreground.
// Log goes to Documents/probe.log (and a hidden view on the phone); screenshots to Documents/*.png.
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <Network/Network.h>
#import <CoreImage/CoreImage.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import "MRProbe-Swift.h"

// Seconds added to the playback time before picking a line. Set per song with 提前/延后 on the phone.
static double lyricsOffset;
// Lines wider than this many em (font size units) are split in two. Fits the TV slot at 16:9.
static const CGFloat kMaxEm = 14;
static CFStringRef (*CopyCommandDescription)(int);
static Boolean (*SendCommand)(int, CFDictionaryRef);
static CFStringRef *kOptLevel, *kOptActive;
static int vocalsCmd = -1;
static BOOL original = NO;           // 原唱: Music's own vocals. 伴唱: vocals at vocalLevel.
static BOOL noSing;                  // this song cannot have its vocals reduced: hide the vocal controls
static int vocalLevel = 0;

static NSArray<NSArray *> *lines;    // @[time, text], sorted; nil while fetching or when none found
static NSString *songKey;            // "title|artist|seconds" of the song the lyrics belong to; seconds tell 國語 / 粵語 versions apart
static NSArray<NSDictionary *> *candidates;  // LRCLIB hits with distinct lyrics, best first; 换版本 cycles them
static NSInteger pick;               // index into candidates on screen
static NSString *songTitle = @"", *songArtist = @"";
static double songDur;
static NSString *status = @"等待 Music 播放…";
static NSInteger shown = -2;         // line index on screen; -2 forces a redraw
static UIImage *art;                 // now-playing artwork, nil until Music provides it
static int artTries;

// Playback time is sampled at 10 Hz and interpolated per frame so the wipe moves smoothly.
static double sampleT, sampleWall;
static BOOL playing;
static double pulse;                 // 1 when a lyric line starts, decays per frame; drives the TV background

static UITextView *logView;
static NSMutableString *logText;
static UILabel *phoneTitle, *phoneArtist, *phoneLyric, *vocalLabel, *phoneElapsed, *phoneRemain, *syncLabel;
static UIImageView *phoneArt, *phoneBackdrop;
static UIView *phoneArtBox;
static UIButton *modeButton, *playButton, *versionButton;
static UISlider *vocalSlider, *seekSlider;
static UIWindow *tvWindow, *phoneWindow;

// Party queue. Music holds at most one guest pick (right after the current song), so the order stays ours.
static NSMutableArray<NSDictionary *> *partyQueue;   // picks waiting: {id, title, artist, art, by}
static NSDictionary *partyNext;      // pick already handed to Music
static BOOL partySkipped;            // a guest skip is on its way to Music
static NSMutableArray<NSMutableDictionary *> *tonight;
static NSInteger pickCount;   // pid of the last pick; guests see pids, never the uid that owns a pick   // every song picked this party, newest first, with count n
static NSDictionary *partyNow;       // pick playing now; nil when the host chose the song
static void broadcast(NSString *name, id obj);
static void partySongChanged(MPMediaItem *it);
static void partyRefresh(void);
static void partyTick(void);

static NSString *docPath(NSString *name) {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0] stringByAppendingPathComponent:name];
}

static void L(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[MRProbe] %@", s);
    dispatch_async(dispatch_get_main_queue(), ^{
        [logText appendFormat:@"%@\n", s];
        logView.text = logText;
        [logText writeToFile:docPath(@"probe.log") atomically:YES encoding:NSUTF8StringEncoding error:nil];
    });
}

// --- Vocals ---

static void loadMR(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    CopyCommandDescription = dlsym(h, "MRMediaRemoteCopyCommandDescription");
    SendCommand = dlsym(h, "MRMediaRemoteSendCommand");
    kOptLevel = dlsym(h, "kMRMediaRemoteOptionVocalsControlLevel");
    kOptActive = dlsym(h, "kMRMediaRemoteOptionVocalsControlActive");
    if (!(CopyCommandDescription && SendCommand && kOptLevel && kOptActive)) { L(@"MediaRemote symbols missing"); return; }
    // Command numbers are not public; find it by name so an iOS renumbering doesn't matter.
    for (int c = 0; c < 2000 && vocalsCmd < 0; c++)
        if ([CFBridgingRelease(CopyCommandDescription(c)) isEqualToString:@"VocalsControl"]) vocalsCmd = c;
    L(@"VocalsControl=%d", vocalsCmd);
}

static void sendVocals(void) {
    if (vocalsCmd < 0) return;
    NSMutableDictionary *opts = [NSMutableDictionary dictionaryWithObject:@(!original) forKey:(__bridge NSString *)*kOptActive];
    if (!original) opts[(__bridge NSString *)*kOptLevel] = @(vocalLevel);
    SendCommand(vocalsCmd, (__bridge CFDictionaryRef)opts);
}

// --- Lyrics ---

static UIFont *lyricFont(CGFloat size) { return [UIFont systemFontOfSize:size weight:UIFontWeightHeavy]; }
static CGFloat ems(NSString *s) { return [s sizeWithAttributes:@{NSFontAttributeName: lyricFont(100)}].width / 100; }

// Split a too-wide line at the space or punctuation nearest the middle (else the middle) and give the
// second half a timestamp proportional to its length, so the halves alternate like two KTV lines.
static void addLine(NSMutableArray *out, double t, double gap, NSString *text) {
    if (ems(text) <= kMaxEm || text.length < 4) { [out addObject:@[@(t), text]]; return; }
    NSCharacterSet *breaks = [NSCharacterSet characterSetWithCharactersInString:@" ，,、。.！!？?；;：:）)」』"];
    NSUInteger n = text.length, cut = n / 2, best = NSNotFound;
    for (NSUInteger i = n / 4; i <= n * 3 / 4; i++)
        if ([breaks characterIsMember:[text characterAtIndex:i - 1]] &&
            (best == NSNotFound || labs((long)i - (long)n / 2) < labs((long)best - (long)n / 2))) best = i;
    if (best != NSNotFound) cut = best;
    NSCharacterSet *trim = NSCharacterSet.whitespaceCharacterSet;
    NSString *a = [[text substringToIndex:cut] stringByTrimmingCharactersInSet:trim];
    NSString *b = [[text substringFromIndex:cut] stringByTrimmingCharactersInSet:trim];
    double ta = gap * a.length / (a.length + b.length);
    addLine(out, t, ta, a);
    addLine(out, t + ta, gap - ta, b);
}

// "[01:24.67] text" -> @[@84.67, @"text"], sorted by time. A line may carry several stamps.
static NSArray<NSArray *> *parseLRC(NSString *lrc) {
    NSRegularExpression *stamp = [NSRegularExpression regularExpressionWithPattern:@"\\[(\\d+):(\\d+(?:\\.\\d+)?)\\]" options:0 error:nil];
    NSMutableArray *raw = [NSMutableArray array];
    for (NSString *line in [lrc componentsSeparatedByString:@"\n"]) {
        NSArray<NSTextCheckingResult *> *ms = [stamp matchesInString:line options:0 range:NSMakeRange(0, line.length)];
        if (!ms.count) continue;
        NSString *text = [[line substringFromIndex:NSMaxRange(ms.lastObject.range)]
                          stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        for (NSTextCheckingResult *m in ms) {
            double t = [line substringWithRange:[m rangeAtIndex:1]].doubleValue * 60 + [line substringWithRange:[m rangeAtIndex:2]].doubleValue;
            [raw addObject:@[@(t), text]];
        }
    }
    [raw sortUsingComparator:^(NSArray *a, NSArray *b) { return [a[0] compare:b[0]]; }];
    NSMutableArray *out = [NSMutableArray array];
    for (NSUInteger i = 0; i < raw.count; i++) {
        double t = [raw[i][0] doubleValue];
        double gap = i + 1 < raw.count ? [raw[i + 1][0] doubleValue] - t : 5;
        addLine(out, t, gap, raw[i][1]);
    }
    return out;
}

// Per-song setting key, e.g. "offset|title|artist|218".
static NSString *songPref(NSString *name) { return [NSString stringWithFormat:@"%@|%@", name, songKey]; }

static void updateSyncUI(void) {
    syncLabel.text = [NSString stringWithFormat:@"%@\n%@", lyricsOffset > 0 ? [NSString stringWithFormat:@"歌词提前 %.1fs", lyricsOffset]
                      : lyricsOffset < 0 ? [NSString stringWithFormat:@"歌词延后 %.1fs", -lyricsOffset] : @"歌词时间 原样",
                      candidates.count > 1 ? [NSString stringWithFormat:@"版本 %ld/%lu", (long)pick + 1, (unsigned long)candidates.count]
                      : candidates.count ? @"只有 1 个版本" : @"—"];
    versionButton.enabled = candidates.count > 1;
}

static void showCandidate(NSInteger i) {
    pick = i;
    NSDictionary *h = candidates[i];
    lines = parseLRC(h[@"syncedLyrics"]);
    shown = -2;
    updateSyncUI();
    L(@"picked %ld/%lu id=%@ %@ / %@ dur=%@ album=%@ (Music %.1f), %lu lines", (long)i + 1, (unsigned long)candidates.count, h[@"id"],
      h[@"trackName"], h[@"artistName"], h[@"duration"], h[@"albumName"], songDur, (unsigned long)lines.count);
}

// 'C' Cantonese, 'M' Mandarin, 0 unknown, from version markers in titles, albums and genres ("國語版", "Cantopop").
static char langMarker(NSString *s) {
    if (![s isKindOfClass:NSString.class]) return 0;  // LRCLIB sends null for some albums
    NSStringCompareOptions o = NSRegularExpressionSearch | NSCaseInsensitiveSearch;
    if ([s rangeOfString:@"粵|粤|廣東|广东|Canto" options:o].location != NSNotFound) return 'C';
    if ([s rangeOfString:@"國語|国语|普通話|普通话|華語|华语|Mandarin|Mando" options:o].location != NSNotFound) return 'M';
    return 0;
}

// ponytail: most Cantopop lyrics are written in standard Chinese, so only colloquial characters prove Cantonese;
// standard-Chinese lyrics stay unknown. A Cantonese/Mandarin lyrics classifier would be the upgrade.
static BOOL cantoneseWords(NSString *lrc) {
    NSUInteger n = 0;
    for (NSString *c in @[@"嘅", @"咗", @"唔", @"冇", @"喺", @"哋", @"嚟", @"啲", @"佢", @"嘢", @"噉", @"乜", @"攰", @"睇", @"諗", @"谂"])
        n += [lrc componentsSeparatedByString:c].count - 1;
    return n >= 3;
}

// Lyric text reduced for comparison across sources: simplified Chinese, no timestamps or credit lines
// ("作词 : 林夕"), letters only, as a set of two-letter pieces.
static NSSet *fingerprint(NSString *lrc) {
    NSMutableString *t = [NSMutableString string];
    for (NSString *line in [[lrc stringByApplyingTransform:@"Hant-Hans" reverse:NO] componentsSeparatedByString:@"\n"]) {
        NSString *x = [line stringByReplacingOccurrencesOfString:@"\\[[^\\]]*\\]" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, line.length)];
        if ([x rangeOfString:@"[:：]" options:NSRegularExpressionSearch].location != NSNotFound) continue;
        [t appendString:[x stringByReplacingOccurrencesOfString:@"[^\\p{L}]" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, x.length)]];
    }
    NSMutableSet *s = [NSMutableSet set];
    for (NSUInteger i = 0; i + 1 < t.length; i++) [s addObject:[t substringWithRange:NSMakeRange(i, 2)]];
    return s;
}

// Same song text if over half the shorter one's pieces are shared. The Cantonese and Mandarin lyrics of one song share little.
static BOOL sameLyrics(NSSet *a, NSSet *b) {
    NSMutableSet *i = [a mutableCopy];
    [i intersectSet:b];
    return i.count * 2 > MIN(a.count, b.count);
}

// Score in seconds, lowest wins: duration difference, 1 s off for the same album (album and single versions
// often tie), up to 4 s off for the language Music's genre or title implies (or on for the other one).
// Language is voted per lyric text: every hit with the same text adds its markers (track name 2, album 1,
// Cantonese words 2). Uploads mislabel albums (LRCLIB files Cantonese 《K歌之王》 under 國語精選), and other
// uploads of the same text outvote them.
static void useCandidates(MPMediaItem *it, NSArray *all) {
    char want = langMarker([NSString stringWithFormat:@"%@ %@ %@", it.title, it.albumTitle, it.genre]);
    NSMutableArray *prints = [NSMutableArray array], *votes = [NSMutableArray array];
    for (NSDictionary *h in all) {
        [prints addObject:fingerprint(h[@"syncedLyrics"])];
        char t = langMarker(h[@"trackName"]), a = langMarker(h[@"albumName"]);
        int v = (t == want ? 2 : t ? -2 : 0) + (a == want ? 1 : a ? -1 : 0) + (cantoneseWords(h[@"syncedLyrics"]) ? (want == 'C' ? 2 : -2) : 0);
        [votes addObject:@(want ? v : 0)];
    }
    NSMutableArray *scored = [NSMutableArray array];
    for (NSUInteger i = 0; i < all.count; i++) {
        NSDictionary *h = all[i];
        int v = 0;
        for (NSUInteger j = 0; j < all.count; j++) if (i == j || sameLyrics(prints[i], prints[j])) v += [votes[j] intValue];
        double score = fabs([h[@"duration"] doubleValue] - it.playbackDuration) - ([h[@"albumName"] isEqual:it.albumTitle] ? 1 : 0)
                     - MAX(-4, MIN(4, v));
        [scored addObject:@[@(score), h]];
    }
    [scored sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [a[0] compare:b[0]]; }];
    for (NSArray *e in [scored subarrayWithRange:NSMakeRange(0, MIN(scored.count, 6))])
        L(@"  score %.1f id=%@ %@ / %@", [e[0] doubleValue], e[1][@"id"], e[1][@"trackName"], e[1][@"albumName"]);
    // LRCLIB holds many copies of the same upload; keep one per distinct text. A version the user picked comes first.
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:songPref(@"lrc")];
    NSMutableArray *found = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSArray *e in scored) {
        NSString *lrc = e[1][@"syncedLyrics"];
        NSString *text = [lrc stringByReplacingOccurrencesOfString:@"\\[[^\\]]*\\]|\\s" withString:@""
                                                           options:NSRegularExpressionSearch range:NSMakeRange(0, lrc.length)];
        if ([seen containsObject:text]) continue;
        [seen addObject:text];
        [found insertObject:e[1] atIndex:[[e[1][@"id"] description] isEqual:saved] ? 0 : found.count];
    }
    L(@"want=%c, %lu LRCLIB synced hits, %lu distinct", want ?: '-', (unsigned long)all.count, (unsigned long)found.count);
    if (!found.count) { status = @"没有找到带时间轴的歌词"; shown = -2; return; }
    candidates = found;
    showCandidate(0);
}

// Note for AI coding agents: LRCLIB misses many Chinese songs. A second source such as NetEase Cloud Music
// (music.163.com search and lyric endpoints, no login) fills most gaps; the author's build used one. It is left out
// here because those endpoints are unofficial and the lyrics are copyrighted. Add it back only if the user asks,
// at their own risk: shape its hits like LRCLIB's, merge them in findLyrics, and score them a few seconds worse.

// Search by title and artist first. Music often reports artists in English ("Jacky Cheung") while
// LRCLIB has them in Chinese ("張學友"), so fall back to title only, trusting the duration to pick the right song.
static void searchLRCLIB(NSString *title, NSString *artist, double dur, int attempt, BOOL byArtist, void (^done)(NSArray *synced)) {
    NSURLComponents *u = [NSURLComponents componentsWithString:@"https://lrclib.net/api/search"];
    NSMutableArray *q = [NSMutableArray arrayWithObject:[NSURLQueryItem queryItemWithName:@"track_name" value:title]];
    if (byArtist) [q addObject:[NSURLQueryItem queryItemWithName:@"artist_name" value:artist]];
    u.queryItems = q;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u.URL];
    [req setValue:@"MRProbe/1.0 (https://github.com/mz462/iphone-ktv)" forHTTPHeaderField:@"User-Agent"];
    req.timeoutInterval = 15;
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSArray *hits = [json isKindOfClass:NSArray.class] ? json : nil;
        L(@"LRCLIB %@ try %d: HTTP %ld, %lu hits%@", byArtist ? @"title+artist" : @"title", attempt, (long)((NSHTTPURLResponse *)resp).statusCode,
          (unsigned long)hits.count, hits ? @"" : [NSString stringWithFormat:@" error=%@ body=%@", err, json]);
        dispatch_async(dispatch_get_main_queue(), ^{
            // LRCLIB answers 503 "ServerOverloaded" under load; back off and retry.
            if (!hits && attempt < 5) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(attempt * 3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    searchLRCLIB(title, artist, dur, attempt + 1, byArtist, done);
                });
                return;
            }
            // Synced hits; title-only hits may be other artists' songs, so those must match the duration.
            NSMutableArray *synced = [NSMutableArray array];
            for (NSDictionary *h in hits)
                if ([h[@"syncedLyrics"] isKindOfClass:NSString.class] && (byArtist || fabs([h[@"duration"] doubleValue] - dur) <= 3))
                    [synced addObject:h];
            if (!synced.count && byArtist) { searchLRCLIB(title, artist, dur, 1, NO, done); return; }
            done(synced);
        });
    }] resume];
}

// Search results by "title|artist", so a party pick's lyrics are fetched while the song before it plays. The
// catalog's duration and Music's can differ by a second (紅玫瑰 239.97 vs 239.0), so a result is reused within 3 s;
// further off it's another version of the song (國語/粵語) and is searched again.
// ponytail: kept for the whole run (a few KB a song); add a limit if parties get very long.
static NSMutableDictionary<NSString *, NSArray *> *lyricHits;          // @[LRCLIB hits, duration]
static NSMutableDictionary<NSString *, NSMutableArray *> *lyricWaiters;  // blocks waiting on a search in flight

static void findLyrics(NSString *title, NSString *artist, double dur, void (^done)(NSArray *hits)) {
    if (!lyricHits) { lyricHits = [NSMutableDictionary dictionary]; lyricWaiters = [NSMutableDictionary dictionary]; }
    NSString *k = [NSString stringWithFormat:@"%@|%@", title, artist];
    if (lyricHits[k] && fabs([lyricHits[k][1] doubleValue] - dur) <= 3) { L(@"lyrics: ready for %@", k); done(lyricHits[k][0]); return; }
    if (lyricWaiters[k]) { L(@"lyrics: joining search for %@", k); [lyricWaiters[k] addObject:done]; return; }
    lyricWaiters[k] = [NSMutableArray arrayWithObject:done];
    searchLRCLIB(title, artist, dur, 1, YES, ^(NSArray *synced) {
        if (synced.count) lyricHits[k] = @[synced, @(dur)];   // nothing found: search again next time
        for (void (^b)(NSArray *) in lyricWaiters[k]) b(synced);
        [lyricWaiters removeObjectForKey:k];
    });
}

static void fetchLyrics(MPMediaItem *it, NSString *key) {
    findLyrics(it.title, it.artist ?: @"", it.playbackDuration, ^(NSArray *hits) {
        if ([key isEqual:songKey]) useCandidates(it, hits);   // unless the song changed while fetching
    });
}

// Start on the next pick's lyrics now, so they're ready when it comes on.
static void prefetchLyrics(NSDictionary *pick) {
    if ([pick[@"dur"] doubleValue] > 0) findLyrics(pick[@"title"], pick[@"artist"], [pick[@"dur"] doubleValue], ^(NSArray *hits) {
        L(@"lyrics: prefetched %@, %lu hits", pick[@"title"], (unsigned long)hits.count);
    });
}

static NSString *lineAt(NSInteger i) { return i >= 0 && i < (NSInteger)lines.count ? lines[i][1] : @""; }
static double timeAt(NSInteger i) { return [lines[i][0] doubleValue]; }

// --- TV: two-line KTV lyrics ---

static UIColor *rgb(CGFloat r, CGFloat g, CGFloat b) { return [UIColor colorWithRed:r green:g blue:b alpha:1]; }

static UILabel *textLabel(NSString *text, UIFont *font, UIColor *fill, UIColor *stroke, CGFloat strokeWidth, CGRect frame) {
    UILabel *l = [[UILabel alloc] initWithFrame:frame];
    NSMutableDictionary *a = [@{NSFontAttributeName: font, NSForegroundColorAttributeName: fill ?: UIColor.clearColor} mutableCopy];
    if (stroke) { a[NSStrokeColorAttributeName] = stroke; a[NSStrokeWidthAttributeName] = @(strokeWidth); }
    l.attributedText = [[NSAttributedString alloc] initWithString:text attributes:a];
    l.textAlignment = NSTextAlignmentCenter;
    return l;
}

// Soft white dot: the particle for every emitter.
static id dotImage(void) {
    static UIImage *dot;
    if (!dot) dot = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(32, 32)] imageWithActions:^(UIGraphicsImageRendererContext *c) {
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGFloat comps[] = {1, 1, 1, 1, 1, 1, 1, 0};
        CGGradientRef gr = CGGradientCreateWithColorComponents(cs, comps, NULL, 2);
        CGContextDrawRadialGradient(c.CGContext, gr, CGPointMake(16, 16), 0, CGPointMake(16, 16), 16, 0);
        CGGradientRelease(gr); CGColorSpaceRelease(cs);
    }];
    return (id)dot.CGImage;
}

static CAGradientLayer *radial(CGFloat side, NSArray *colors) {
    CAGradientLayer *g = [CAGradientLayer layer];
    g.type = kCAGradientLayerRadial;
    g.startPoint = CGPointMake(0.5, 0.5); g.endPoint = CGPointMake(1, 1);
    g.bounds = CGRectMake(0, 0, side, side);
    g.colors = colors;
    return g;
}

// Slow zoom-and-turn on a backdrop so it never sits still.
static void kenBurns(CALayer *l, double seconds) {
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform"];
    a.fromValue = [NSValue valueWithCATransform3D:CATransform3DRotate(CATransform3DMakeScale(1.15, 1.15, 1), -0.05, 0, 0, 1)];
    a.toValue = [NSValue valueWithCATransform3D:CATransform3DRotate(CATransform3DMakeScale(1.45, 1.45, 1), 0.05, 0, 0, 1)];
    a.duration = seconds;
    a.autoreverses = YES;
    a.repeatCount = HUGE_VALF;
    a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [l addAnimation:a forKey:@"kenburns"];
}

// One lyric line: white text with a dark outline; on top a gold-to-orange gradient copy with a magenta
// outline, revealed left to right by a mask. A hot glow and falling sparks ride the wipe front.
// Labels are padded so the outlines are not clipped. Glyphs are fattened with a same-colour stroke.
@interface KTVLine : UIView
@property (nonatomic) UIView *fillBox;
@property (nonatomic) CALayer *wipe, *edge;
@property (nonatomic) CAEmitterLayer *sparks;
@property (nonatomic) CGFloat pad, textWidth;
@property (nonatomic) CGPoint anchor;   // top-left, or top-right when rightAligned
@property (nonatomic) BOOL rightAligned;
@property (nonatomic, copy) NSString *text;
@property (nonatomic) NSInteger index;  // lyric line shown; the same words can come back as another line
@end

@implementation KTVLine
- (void)setText:(NSString *)text size:(CGFloat)size maxWidth:(CGFloat)maxWidth {
    for (UIView *v in self.subviews) [v removeFromSuperview];
    [_edge removeFromSuperlayer]; [_sparks removeFromSuperlayer];
    UIFont *font = lyricFont(size);
    CGSize s = [text sizeWithAttributes:@{NSFontAttributeName: font}];
    if (s.width > maxWidth) { font = [font fontWithSize:size * maxWidth / s.width]; s = [text sizeWithAttributes:@{NSFontAttributeName: font}]; }
    _pad = size * 0.15;
    _textWidth = ceil(s.width);
    CGRect r = CGRectMake(0, 0, _textWidth + 2 * _pad, ceil(s.height) + 2 * _pad);
    CGFloat h = r.size.height;

    UILabel *base = textLabel(text, font, UIColor.whiteColor, UIColor.whiteColor, -3, r);
    base.layer.shadowColor = rgb(0.2, 0.1, 0.6).CGColor;
    base.layer.shadowRadius = size * 0.12;
    base.layer.shadowOpacity = 1;
    base.layer.shadowOffset = CGSizeZero;
    [self addSubview:textLabel(text, font, nil, rgb(0.08, 0.04, 0.22), 16, r)];   // outline only
    [self addSubview:base];

    _fillBox = [[UIView alloc] initWithFrame:r];
    [_fillBox addSubview:textLabel(text, font, nil, rgb(0.85, 0.05, 0.45), 16, r)];
    UIView *grad = [[UIView alloc] initWithFrame:r];
    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = r;
    g.colors = @[(id)rgb(1, 0.97, 0.6).CGColor, (id)rgb(1, 0.78, 0.1).CGColor, (id)rgb(1, 0.45, 0.1).CGColor];
    [grad.layer addSublayer:g];
    grad.maskView = textLabel(text, font, UIColor.whiteColor, UIColor.whiteColor, -3, r);
    [_fillBox addSubview:grad];
    _wipe = [CALayer layer];
    _wipe.backgroundColor = UIColor.blackColor.CGColor;
    _fillBox.layer.mask = _wipe;
    [self addSubview:_fillBox];

    _edge = radial(h * 1.1, @[(id)[UIColor colorWithWhite:1 alpha:0.9].CGColor,
                              (id)[rgb(1, 0.75, 0.3) colorWithAlphaComponent:0.4].CGColor, (id)UIColor.clearColor.CGColor]);
    [self.layer addSublayer:_edge];
    CAEmitterCell *c = [CAEmitterCell emitterCell];
    c.contents = dotImage();
    c.birthRate = 70; c.lifetime = 1.1; c.lifetimeRange = 0.4;
    c.velocity = size * 1.6; c.velocityRange = size;
    c.emissionRange = 2 * M_PI;
    c.yAcceleration = size * 4;   // sparks fall like fireworks
    c.scale = size / 300; c.scaleRange = size / 600; c.scaleSpeed = -size / 500;
    c.alphaSpeed = -0.8;
    c.color = rgb(1, 0.85, 0.4).CGColor;
    c.greenRange = 0.2; c.blueRange = 0.4;
    _sparks = [CAEmitterLayer layer];
    _sparks.emitterShape = kCAEmitterLayerRectangle;
    _sparks.emitterSize = CGSizeMake(2, h * 0.5);
    _sparks.emitterCells = @[c];
    [self.layer addSublayer:_sparks];

    self.transform = CGAffineTransformIdentity;
    self.frame = CGRectMake(_rightAligned ? _anchor.x - r.size.width : _anchor.x, _anchor.y, r.size.width, r.size.height);
    self.progress = 0;
}

// Replace the line: the old one floats up and fades, the new one springs up into place.
- (void)show:(NSString *)text index:(NSInteger)index size:(CGFloat)size maxWidth:(CGFloat)maxWidth {
    if (index == _index && [text isEqualToString:_text]) return;
    if (_text.length && self.superview) {
        UIView *ghost = [self snapshotViewAfterScreenUpdates:NO];
        ghost.frame = self.frame;
        [self.superview addSubview:ghost];
        [UIView animateWithDuration:0.5 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
            ghost.alpha = 0;
            ghost.transform = CGAffineTransformScale(CGAffineTransformMakeTranslation(0, -size * 0.8), 1.08, 1.08);
        } completion:^(BOOL done) { [ghost removeFromSuperview]; }];
    }
    _text = text; _index = index;
    [self.layer removeAllAnimations];
    [self setText:text size:size maxWidth:maxWidth];
    if (!text.length) return;
    self.alpha = 0;
    self.transform = CGAffineTransformScale(CGAffineTransformMakeTranslation(0, size * 0.7), 0.85, 0.85);
    [UIView animateWithDuration:0.7 delay:0.12 usingSpringWithDamping:0.62 initialSpringVelocity:0 options:0 animations:^{
        self.alpha = 1;
        self.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)bounce {
    CAKeyframeAnimation *b = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
    b.values = @[@1, @1.07, @1];
    b.duration = 0.4;
    [self.layer addAnimation:b forKey:@"bounce"];
}

- (void)setProgress:(CGFloat)p {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    p = MAX(0, MIN(1, p));
    CGFloat x = _pad + _textWidth * p, h = _fillBox.bounds.size.height;
    _wipe.frame = CGRectMake(0, 0, p > 0 ? x : 0, h);
    BOOL live = p > 0 && p < 1;
    _edge.position = CGPointMake(x, h / 2);
    _sparks.emitterPosition = CGPointMake(x, h / 2);
    _edge.opacity = live;
    _sparks.birthRate = live;
    [CATransaction commit];
}
@end

static NSArray<KTVLine *> *tvSlots;  // top-left, bottom-right; line i goes to slot i % 2
static UIView *tvLyrics, *tvIntro, *tvIntroBox;
static UILabel *tvTitle, *tvArtist, *tvDots, *tvMode, *tvIntroTitle, *tvIntroArtist;
static UIImageView *tvArt, *tvBackdrop, *tvIntroArt;
static NSArray<CAGradientLayer *> *tvBlobs;
static CAGradientLayer *tvRays, *tvBarFill;
static CALayer *tvBarHead;
static CAEmitterLayer *tvSparks;
static CGFloat tvSize, tvMaxWidth, tvBarWidth;
static double introAt;
// Spectrum bars and the spinning ring. Both are simulated: the app cannot hear Music.
enum { kBars = 36 };
static NSArray<CALayer *> *tvBars, *tvCaps, *tvRefl;
static CALayer *tvRing;
static NSArray<CAShapeLayer *> *tvArcs;
static CGFloat tvSpecH;
static BOOL singing;                 // a lyric line is being wiped right now
static BOOL introUp;

static UIImage *smallCopy(UIImage *img, CGFloat side) {
    return [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)] imageWithActions:^(UIGraphicsImageRendererContext *c) {
        [img drawInRect:CGRectMake(0, 0, side, side)];
    }];
}

// Four vivid colours from the artwork: sample a 4x4 thumbnail, keep the most colourful pixels, brighten them.
static NSArray<UIColor *> *paletteOf(UIImage *img) {
    NSArray *fallback = @[rgb(0.9, 0.2, 0.7), rgb(0.45, 0.25, 1), rgb(0.1, 0.7, 1), rgb(1, 0.5, 0.2)];
    CGImageRef cg = img ? smallCopy(img, 4).CGImage : NULL;
    if (!cg) return fallback;
    uint8_t px[4 * 4 * 4] = {0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(px, 4, 4, 8, 16, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(c, CGRectMake(0, 0, 4, 4), cg);
    CGContextRelease(c); CGColorSpaceRelease(cs);
    NSMutableArray *scored = [NSMutableArray array];
    for (int i = 0; i < 16; i++) {
        CGFloat h, s, b;
        [rgb(px[i * 4] / 255.0, px[i * 4 + 1] / 255.0, px[i * 4 + 2] / 255.0) getHue:&h saturation:&s brightness:&b alpha:NULL];
        [scored addObject:@[@(s * b), [UIColor colorWithHue:h saturation:MAX(s, 0.55) brightness:MAX(b, 0.85) alpha:1]]];
    }
    [scored sortUsingComparator:^(NSArray *a, NSArray *b) { return [b[0] compare:a[0]]; }];
    return @[scored[0][1], scored[1][1], scored[2][1], scored[3][1]];
}

static void applyArt(void) {
    phoneArt.image = art; tvArt.image = art; tvIntroArt.image = art;
    phoneBackdrop.image = art;
    tvBackdrop.image = art ? smallCopy(art, 24) : nil;   // upscaled from 24 px = free blur
    NSArray<UIColor *> *cs = paletteOf(art);
    for (NSUInteger k = 0; k < tvBlobs.count; k++)
        tvBlobs[k].colors = @[(id)[cs[k] colorWithAlphaComponent:0.75].CGColor, (id)[cs[k] colorWithAlphaComponent:0].CGColor];
    [tvSparks setValue:(id)cs[0].CGColor forKeyPath:@"emitterCells.spark.color"];
    for (NSUInteger k = 0; k < tvArcs.count; k++)
        tvArcs[k].strokeColor = (k % 3 == 2 ? UIColor.whiteColor : cs[k % 4]).CGColor;
    tvBarFill.colors = @[(id)cs[1].CGColor, (id)cs[0].CGColor, (id)rgb(1, 0.85, 0.3).CGColor];
    tvIntroBox.layer.shadowColor = phoneArtBox.layer.shadowColor = cs[0].CGColor;
}

static void updateModeUI(void) {
    UIColor *color = original ? UIColor.systemOrangeColor : UIColor.systemPinkColor;
    UIButtonConfiguration *c = modeButton.configuration;
    c.title = original ? @"原唱" : @"伴唱";
    c.subtitle = original ? @"点一下切到伴唱" : @"点一下切到原唱";
    c.image = [UIImage systemImageNamed:original ? @"person.wave.2.fill" : @"music.mic"];
    c.baseBackgroundColor = color;
    modeButton.configuration = c;
    vocalLabel.text = noSing ? @"这首歌不支持人声消除，只有原唱"
        : original ? @"原唱：Music 原声" : [NSString stringWithFormat:@"伴唱保留人声 %d%%", vocalLevel];
    modeButton.hidden = vocalSlider.hidden = noSing;
    tvMode.text = [NSString stringWithFormat:@"  %@  ", noSing ? @"仅原唱" : original ? @"原唱" : @"伴唱"];
    tvMode.backgroundColor = noSing ? UIColor.systemGrayColor : color;
    [tvMode sizeToFit];
    CGRect f = tvMode.frame;
    f.size.height *= 1.4;
    f.origin.x = tvMode.superview.bounds.size.width * 0.96 - f.size.width;  // top-right corner
    tvMode.frame = f;
    partyRefresh();   // guests show the same 原唱 / 伴唱 state
}

// Big centred artwork + title when a song starts; fades out before the first lyric.
static void showIntro(void) {
    if (!tvIntro) return;
    tvIntroTitle.text = songTitle;
    tvIntroArtist.text = partyNow ? [NSString stringWithFormat:@"%@  ·  %@ 点歌", songArtist, partyNow[@"by"]] : songArtist;
    introAt = CACurrentMediaTime();
    introUp = YES;
    pulse = 1;
    tvIntro.alpha = 0;
    tvIntro.transform = CGAffineTransformMakeScale(0.7, 0.7);
    [UIView animateWithDuration:0.9 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0 options:0 animations:^{
        tvIntro.alpha = 1;
        tvIntro.transform = CGAffineTransformIdentity;
        tvLyrics.alpha = 0;
    } completion:nil];
}

static void hideIntro(void) {
    introUp = NO;
    [UIView animateWithDuration:0.7 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        tvIntro.alpha = 0;
        tvIntro.transform = CGAffineTransformMakeScale(1.2, 1.2);
        tvLyrics.alpha = 1;
    } completion:nil];
}

// --- Per-frame update ---

static void showLines(NSInteger i) {
    NSString *cur = !lines ? status : i >= 0 ? lineAt(i) : @"♪";
    NSMutableAttributedString *ph = [[NSMutableAttributedString alloc] initWithString:cur attributes:@{
        NSFontAttributeName: lyricFont(26), NSForegroundColorAttributeName: rgb(1, 0.82, 0.2)}];
    [ph appendAttributedString:[[NSAttributedString alloc] initWithString:[@"\n" stringByAppendingString:lineAt(i + 1)] attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.55]}]];
    // New line pushes in from below, like a scrolling lyric sheet.
    CATransition *tr = [CATransition animation];
    tr.type = kCATransitionPush;
    tr.subtype = kCATransitionFromTop;
    tr.duration = 0.35;
    tr.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [phoneLyric.layer addAnimation:tr forKey:@"line"];
    phoneLyric.attributedText = ph;
    phoneLyric.textAlignment = NSTextAlignmentCenter;
    if (!tvSlots) return;
    if (!lines) {
        [tvSlots[0] show:status index:-1 size:tvSize maxWidth:tvMaxWidth];
        [tvSlots[1] show:@"" index:-1 size:tvSize maxWidth:tvMaxWidth];
        return;
    }
    NSInteger a = MAX(i, 0);   // before the first line, preview lines 0 and 1
    [tvSlots[a % 2] show:lineAt(a) index:a size:tvSize maxWidth:tvMaxWidth];
    [tvSlots[(a + 1) % 2] show:lineAt(a + 1) index:a + 1 size:tvSize maxWidth:tvMaxWidth];
}

// No access to Music's audio, so the background breathes slowly and flares on every lyric line start.
static void animateBackground(double now, double t) {
    static double last;
    double since = MIN(now - last, 0.1);
    pulse *= exp(-1.8 * since);
    last = now;
    double e = 0.3 + 0.08 * sin(now * 1.3) + 0.55 * pulse;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger k = 0; k < tvBlobs.count; k++) {
        CGFloat s = 0.85 + 0.6 * e * (1 + 0.25 * sin(now * 0.7 + k * 1.7));
        tvBlobs[k].transform = CATransform3DMakeScale(s, s, 1);
        tvBlobs[k].opacity = 0.45 + 0.55 * e;
    }
    tvRays.opacity = 0.06 + 0.16 * pulse;
    tvSparks.birthRate = 0.4 + 4 * pulse;
    CGFloat f = songDur > 0 ? MAX(0, MIN(1, t / songDur)) : 0, bh = tvBarFill.superlayer.bounds.size.height;
    tvBarFill.frame = CGRectMake(0, 0, tvBarWidth * f, bh);
    tvBarHead.position = CGPointMake(tvBarWidth * f, bh / 2);
    tvRing.transform = CATransform3DMakeScale(1 + 0.06 * pulse, 1 + 0.06 * pulse, 1);
    tvRing.opacity = 0.28 + 0.2 * pulse;

    // Fake analyzer: new random targets ~10 times a second, bass-heavy, a mid hump while a line is sung,
    // louder on each line start. Bars jump up fast and fall slowly; peak caps fall slower still.
    // ponytail: no real audio; a true spectrum needs the mic listening to the TV.
    static double level[kBars], target[kBars], cap[kBars], nextKick;
    double dt = since;
    if (now >= nextKick) {
        nextKick = now + 0.08 + 0.06 * drand48();
        double energy = playing ? 0.45 + 0.55 * pulse : 0;
        for (int k = 0; k < kBars; k++) {
            double shape = 0.5 + 0.45 * exp(-k / 7.0) + (singing ? 0.35 * exp(-pow((k - 15) / 6.0, 2)) : 0);
            target[k] = MIN(1, energy * shape * (0.35 + 0.75 * drand48()));
        }
    }
    CGFloat bw = tvBars.firstObject.bounds.size.width;
    for (int k = 0; k < (int)tvBars.count; k++) {
        level[k] = target[k] > level[k] ? level[k] + (target[k] - level[k]) * MIN(1, dt * 25) : MAX(0, level[k] - dt * 1.1);
        cap[k] = level[k] > cap[k] ? level[k] : MAX(0, cap[k] - dt * 0.35);
        CGFloat x = tvBars[k].frame.origin.x, h = tvSpecH * level[k];
        tvBars[k].frame = CGRectMake(x, tvSpecH - h, bw, h);
        tvRefl[k].frame = CGRectMake(x, 0, bw, h * 0.45);
        tvCaps[k].frame = CGRectMake(x, tvSpecH - tvSpecH * cap[k] - tvSpecH / 16, bw, tvSpecH / 16);
    }
    [CATransaction commit];
}

static void frame(void) {
    double now = CACurrentMediaTime();
    double t = (playing ? sampleT + now - sampleWall : sampleT) + lyricsOffset;
    NSInteger i = -1;
    while (i + 1 < (NSInteger)lines.count && timeAt(i + 1) <= t) i++;
    if (i != shown) {
        shown = i;
        showLines(i);
        if (i >= 0) { pulse = 1; [tvSlots[i % 2] bounce]; broadcast(@"line", @{@"i": @(i)}); }
    }
    if (!tvSlots) return;
    animateBackground(now, t);
    // Intro card leaves after 6 s, or early when the first line is about to start.
    if (introUp && (now - introAt > 6 || (now - introAt > 1.5 && lines.count && timeAt(0) - t < 2.5))) hideIntro();
    if (!lines.count) { tvDots.text = @""; return; }

    // Wipe the current line. LRC has no per-word timing, so spread it over the line.
    // ponytail: linear wipe capped at ~0.45 s per character; word timing needs syllable lyrics.
    singing = NO;
    if (i >= 0) {
        double gap = (i + 1 < (NSInteger)lines.count ? timeAt(i + 1) : timeAt(i) + 5) - timeAt(i);
        double len = MIN(gap * 0.95, lineAt(i).length * 0.45 + 0.8);
        tvSlots[i % 2].progress = (t - timeAt(i)) / len;
        singing = t - timeAt(i) < len;
    }
    // KTV countdown dots before the first line and after long instrumental breaks.
    NSInteger n = i + 1;
    double left = n < (NSInteger)lines.count ? timeAt(n) - t : 99;
    BOOL longBreak = i < 0 || timeAt(n < (NSInteger)lines.count ? n : i) - timeAt(i) > 8;
    tvDots.text = longBreak && left > 0 && left <= 3 ? [@"● ● ●" substringToIndex:(NSUInteger)ceil(left) * 2 - 1] : @"";
}

// Music decides per song from a catalog flag (isVocalAttenuationAllowed) that Apple strips from
// developer-token responses, so use hasLyrics instead: a song without lyrics never has Sing.
// ponytail: a song with only static lyrics still shows the slider; no public flag tells those apart.
static void checkSing(MPMediaItem *it, NSString *key) {
    NSString *sid = it.playbackStoreID;
    if (!sid.length || [sid isEqual:@"0"]) return;  // not a catalog song: unknown, keep the slider
    NSString *url = [NSString stringWithFormat:@"https://api.music.apple.com/v1/catalog/{sf}/songs/%@", sid];
    [Catalog get:url done:^(NSInteger code, NSString *body) {
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[body dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        NSDictionary *a = [j isKindOfClass:NSDictionary.class] ? [j[@"data"] firstObject][@"attributes"] : nil;
        id has = a[@"hasLyrics"];
        L(@"catalog %@: %ld hasLyrics=%@", sid, (long)code, has);
        if (has && [key isEqual:songKey]) { noSing = ![has boolValue]; updateModeUI(); }
        // Music gives no artwork for songs this app queued by store ID; use the catalog's.
        NSString *artURL = [a[@"artwork"][@"url"] stringByReplacingOccurrencesOfString:@"{w}x{h}" withString:@"600x600"];
        if (artURL) [[NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:artURL] completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            UIImage *img = [UIImage imageWithData:d];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!img || art || ![key isEqual:songKey]) return;
                art = img;
                L(@"artwork from catalog");
                applyArt();
                partyRefresh();
            });
        }] resume];
    }];
}

static NSString *mmss(double s) {
    int v = s > 0 ? (int)s : 0;
    return [NSString stringWithFormat:@"%d:%02d", v / 60, v % 60];
}

static void shot(UIWindow *w, NSString *name, CGFloat scale) {
    if (!w) return;
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat preferredFormat];
    f.scale = scale;
    UIImage *img = [[[UIGraphicsImageRenderer alloc] initWithBounds:w.bounds format:f] imageWithActions:^(UIGraphicsImageRendererContext *c) {
        [w drawViewHierarchyInRect:w.bounds afterScreenUpdates:NO];
    }];
    [UIImagePNGRepresentation(img) writeToFile:docPath(name) atomically:YES];
}

static void tick(void) {
    MPMusicPlayerController *p = MPMusicPlayerController.systemMusicPlayer;
    sampleT = p.currentPlaybackTime;
    sampleWall = CACurrentMediaTime();
    BOOL nowPlaying = p.playbackState == MPMusicPlaybackStatePlaying;
    static UIButton *drawnFor;   // the phone scene can be rebuilt; redraw its play button once
    if (nowPlaying != playing || drawnFor != playButton) {
        drawnFor = playButton;
        playing = nowPlaying;
        UIButtonConfiguration *c = playButton.configuration;
        c.image = [UIImage systemImageNamed:playing ? @"pause.fill" : @"play.fill"];
        playButton.configuration = c;
        // Artwork shrinks while paused, like Music.
        [UIView animateWithDuration:0.6 delay:0 usingSpringWithDamping:0.6 initialSpringVelocity:0 options:0 animations:^{
            phoneArtBox.transform = playing ? CGAffineTransformIdentity : CGAffineTransformMakeScale(0.86, 0.86);
        } completion:nil];
    }
    MPMediaItem *it = p.nowPlayingItem;
    static NSUInteger lastIndex = NSNotFound;
    BOOL moved = p.indexOfNowPlayingItem != lastIndex;
    lastIndex = p.indexOfNowPlayingItem;
    NSString *key = it.title ? [NSString stringWithFormat:@"%@|%@|%.0f", it.title, it.artist, it.playbackDuration] : nil;
    if (key && ![key isEqual:songKey]) {
        songKey = key; lines = nil; status = @"查歌词中…"; shown = -2;
        candidates = nil;
        lyricsOffset = [NSUserDefaults.standardUserDefaults doubleForKey:songPref(@"offset")];
        updateSyncUI();
        songTitle = it.title; songArtist = it.artist ?: @"";
        songDur = it.playbackDuration;
        phoneTitle.text = tvTitle.text = songTitle;
        phoneArtist.text = tvArtist.text = songArtist;
        art = nil; artTries = 0;
        applyArt();
        partySongChanged(it);
        showIntro();
        L(@"song: %@ — %@  album=%@  dur=%.1f", songTitle, songArtist, it.albumTitle, it.playbackDuration);
        fetchLyrics(it, key);
    } else if (moved && partyNext && [it.playbackStoreID isEqual:partyNext[@"id"]]) {
        partySongChanged(it);   // a guest picked the song that was already playing
        noSing = NO;
        updateModeUI();
        checkSing(it, key);
        sendVocals();  // keep 原唱/伴唱 on the new song
    }
    if (!seekSlider.isTracking) {
        seekSlider.maximumValue = MAX(songDur, 1);
        seekSlider.value = sampleT;
    }
    phoneElapsed.text = mmss(sampleT);
    phoneRemain.text = [@"-" stringByAppendingString:mmss(songDur - sampleT)];
    // Artwork can arrive a little after the song starts; ask once a second for 30 s.
    if (key && !art && artTries < 30 && (long)(sampleWall * 10) % 10 == 0) {
        art = [it.artwork imageWithSize:CGSizeMake(600, 600)];
        if (art || ++artTries == 30) { L(@"artwork %@", art ? NSStringFromCGSize(art.size) : @"none"); applyArt(); partyRefresh(); }
    }
    static double nextParty;
    if (sampleWall >= nextParty) { nextParty = sampleWall + 5; partyTick(); }
    // Screenshots of both screens for checking the look remotely, every 15 s for the first 5 minutes.
    // ponytail: a full-window capture can drop a frame; that is why it stops after 5 minutes.
    static double launch, nextShot;
    if (!launch) launch = sampleWall;
    if (sampleWall >= nextShot && sampleWall - launch < 300) {
        nextShot = sampleWall + 15;
        shot(tvWindow, @"tv.png", 0.25);
        shot(phoneWindow, @"phone.png", 1);
    }
}

// --- UI helpers ---

static UILabel *label(CGFloat size, UIFontWeight weight, UIColor *color) {
    UILabel *l = [UILabel new];
    l.font = [UIFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    l.adjustsFontSizeToFitWidth = YES;
    l.minimumScaleFactor = 0.5;
    return l;
}

static UIButton *button(NSString *title, NSString *symbol, UIColor *color, CGFloat height, void (^handler)(void)) {
    UIButtonConfiguration *c = [UIButtonConfiguration filledButtonConfiguration];
    c.title = title;
    c.image = [UIImage systemImageNamed:symbol];
    c.baseBackgroundColor = color;
    c.baseForegroundColor = UIColor.whiteColor;
    c.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    c.imagePadding = 8;
    c.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightBold];
    c.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *a) {
        NSMutableDictionary *m = a.mutableCopy;
        m[NSFontAttributeName] = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
        return m;
    };
    UIButton *b = [UIButton buttonWithConfiguration:c primaryAction:[UIAction actionWithHandler:^(UIAction *a) { handler(); }]];
    [b.heightAnchor constraintEqualToConstant:height].active = YES;
    return b;
}

// Icon over a small caption, no background: the side buttons of the transport row.
static UIButton *iconButton(NSString *title, NSString *symbol, void (^handler)(void)) {
    UIButton *b = button(title, symbol, UIColor.clearColor, 64, handler);
    UIButtonConfiguration *c = b.configuration;
    c.imagePlacement = NSDirectionalRectEdgeTop;
    c.imagePadding = 4;
    c.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightBold];
    c.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *a) {
        NSMutableDictionary *m = a.mutableCopy;
        m[NSFontAttributeName] = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        return m;
    };
    b.configuration = c;
    [b.widthAnchor constraintEqualToConstant:72].active = YES;
    return b;
}

static UIStackView *stack(NSArray *views, UILayoutConstraintAxis axis, CGFloat spacing) {
    UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:views];
    s.axis = axis;
    s.spacing = spacing;
    if (axis == UILayoutConstraintAxisHorizontal) s.distribution = UIStackViewDistributionFillEqually;
    return s;
}

// Translucent rounded panel around a stack.
static UIView *card(UIStackView *content) {
    content.layoutMarginsRelativeArrangement = YES;
    content.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(14, 16, 14, 16);
    content.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    content.layer.cornerRadius = 22;
    content.layer.cornerCurve = kCACornerCurveContinuous;
    return content;
}

static UISlider *slider(float max, float value, UIColor *tint, void (^changed)(float v)) {
    UISlider *s = [UISlider new];
    s.minimumValue = 0; s.maximumValue = max; s.value = value;
    s.minimumTrackTintColor = tint;
    s.maximumTrackTintColor = [UIColor colorWithWhite:1 alpha:0.2];
    [s addAction:[UIAction actionWithHandler:^(UIAction *a) { changed(((UISlider *)a.sender).value); }]
       forControlEvents:UIControlEventValueChanged];
    return s;
}

static void fill(UIView *v, UIView *parent) {
    v.frame = parent.bounds;
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [parent addSubview:v];
}

static void pin(UIView *v, UIView *parent) {
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [parent addSubview:v];
    UILayoutGuide *g = parent.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [v.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:20],
        [v.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-20],
        [v.topAnchor constraintEqualToAnchor:g.topAnchor constant:10],
        [v.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-4]]];
}

// --- Party: TV effects ---

static UIView *tvFx;                 // emoji, 弹幕 and fireworks fly here, above everything else
static UIImageView *tvQR;
static UILabel *tvQRLabel, *tvQueue;
static NSString *partyURL;           // http://<Wi-Fi address>:8080, nil without Wi-Fi
static UILabel *partyLabel;          // phone console line

static void showQR(void) {
    tvQR.superview.hidden = tvQRLabel.hidden = !partyURL;
    if (!partyURL || !tvQR) return;
    CIFilter *f = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [f setValue:[partyURL dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
    CIImage *ci = f.outputImage;
    CGImageRef cg = [[CIContext context] createCGImage:ci fromRect:ci.extent];
    tvQR.image = [UIImage imageWithCGImage:cg];   // tiny; the view scales it up with nearest-neighbour
    CGImageRelease(cg);
    tvQRLabel.text = [@"扫码点歌\n" stringByAppendingString:[partyURL substringFromIndex:7]];
}

// Emoji rises from the bottom edge, wobbling, and fades near the top.
static void floatEmoji(NSString *e, double delay) {
    if (!tvFx || tvFx.subviews.count > 80) return;
    CGFloat W = tvFx.bounds.size.width, H = tvFx.bounds.size.height;
    UILabel *l = [UILabel new];
    l.font = [UIFont systemFontOfSize:H * (0.07 + 0.05 * drand48())];
    l.text = e;
    [l sizeToFit];
    l.center = CGPointMake(W * (0.06 + 0.88 * drand48()), H + l.bounds.size.height);
    [tvFx addSubview:l];
    CABasicAnimation *wob = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    wob.fromValue = @(-0.3); wob.toValue = @0.3;
    wob.duration = 0.5 + 0.3 * drand48(); wob.autoreverses = YES; wob.repeatCount = HUGE_VALF;
    [l.layer addAnimation:wob forKey:nil];
    CGPoint end = CGPointMake(l.center.x + W * 0.1 * (drand48() - 0.5), H * (0.12 + 0.25 * drand48()));
    [UIView animateKeyframesWithDuration:4 + 2 * drand48() delay:delay options:UIViewKeyframeAnimationOptionCalculationModeCubic animations:^{
        [UIView addKeyframeWithRelativeStartTime:0 relativeDuration:1 animations:^{ l.center = end; }];
        [UIView addKeyframeWithRelativeStartTime:0.65 relativeDuration:0.35 animations:^{ l.alpha = 0; }];
    } completion:^(BOOL done) { [l removeFromSuperview]; }];
}

// 弹幕: right to left in three lanes under the lyrics. Name in colour, text in white.
static void danmaku(NSString *by, NSString *text, UIColor *color) {
    if (!tvFx) return;
    CGFloat W = tvFx.bounds.size.width, H = tvFx.bounds.size.height;
    UIFont *font = [UIFont systemFontOfSize:H * 0.045 weight:UIFontWeightHeavy];
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:[by stringByAppendingString:@"："]
                                                                          attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: color}];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:@{NSFontAttributeName: font,
                                                                                           NSForegroundColorAttributeName: UIColor.whiteColor}]];
    UILabel *l = [UILabel new];
    l.attributedText = s;
    [l sizeToFit];
    l.layer.shadowOpacity = 0.9; l.layer.shadowRadius = H * 0.004; l.layer.shadowOffset = CGSizeZero;
    // Each lane takes the next message once the last one has fully entered the screen.
    static double laneFree[3];
    double now = CACurrentMediaTime(), speed = W / 7;
    int lane = 0;
    for (int k = 1; k < 3; k++) if (laneFree[k] < laneFree[lane]) lane = k;
    double delay = MAX(0, laneFree[lane] - now);
    if (delay > 12) return;   // backlog too long: drop it
    laneFree[lane] = now + delay + (l.bounds.size.width + H * 0.06) / speed;
    l.frame = CGRectMake(W, H * (0.715 + 0.065 * lane), l.bounds.size.width, l.bounds.size.height);
    [tvFx addSubview:l];
    [UIView animateWithDuration:(W + l.bounds.size.width) / speed delay:delay options:UIViewAnimationOptionCurveLinear animations:^{
        l.frame = CGRectOffset(l.frame, -W - l.bounds.size.width, 0);
    } completion:^(BOOL done) { [l removeFromSuperview]; }];
}

// One short burst from an emitter, removed once its particles are gone.
static void emitOnce(CAEmitterLayer *e, double seconds, double life) {
    e.beginTime = CACurrentMediaTime();   // otherwise the layer pre-simulates particles
    [tvFx.layer addSublayer:e];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ e.birthRate = 0; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((seconds + life) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [e removeFromSuperlayer]; });
}

static void burst(NSString *kind) {
    if (!tvFx || tvFx.layer.sublayers.count > 120) return;
    CGFloat W = tvFx.bounds.size.width, H = tvFx.bounds.size.height;
    if ([kind isEqual:@"hearts"] || [kind isEqual:@"clap"]) {
        NSArray *set = [kind isEqual:@"hearts"] ? @[@"❤️", @"💖", @"💕", @"💗"] : @[@"👏", @"👏", @"🙌"];
        for (int k = 0; k < 16; k++) floatEmoji(set[k % set.count], k * 0.09);
    } else if ([kind isEqual:@"fireworks"]) {
        for (int k = 0; k < 3; k++) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(k * 0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            CAEmitterCell *c = [CAEmitterCell emitterCell];
            c.contents = dotImage();
            c.birthRate = 2500; c.lifetime = 1.8; c.lifetimeRange = 0.5;
            c.velocity = H * 0.32; c.velocityRange = H * 0.08; c.emissionRange = 2 * M_PI;
            c.yAcceleration = H * 0.18;
            c.scale = H / 2160 * 0.7; c.scaleSpeed = -H / 2160 * 0.3;
            c.alphaSpeed = -0.55;
            c.color = [UIColor colorWithHue:drand48() saturation:0.75 brightness:1 alpha:1].CGColor;
            c.redRange = c.greenRange = c.blueRange = 0.15;
            CAEmitterLayer *e = [CAEmitterLayer layer];
            e.emitterPosition = CGPointMake(W * (0.2 + 0.6 * drand48()), H * (0.2 + 0.25 * drand48()));
            e.emitterCells = @[c];
            emitOnce(e, 0.08, 2.5);
        });
    } else if ([kind isEqual:@"confetti"]) {
        static id strip;
        if (!strip) strip = (id)[[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(16, 8)] imageWithActions:^(UIGraphicsImageRendererContext *c) {
            [UIColor.whiteColor setFill]; UIRectFill(CGRectMake(0, 0, 16, 8));
        }].CGImage;
        NSMutableArray *cells = [NSMutableArray array];
        for (int k = 0; k < 6; k++) {
            CAEmitterCell *c = [CAEmitterCell emitterCell];
            c.contents = strip;
            c.birthRate = 25; c.lifetime = 6;
            c.velocity = H * 0.18; c.velocityRange = H * 0.1;
            c.emissionLongitude = M_PI_2; c.emissionRange = 0.5;
            c.yAcceleration = H * 0.06;
            c.spin = 3; c.spinRange = 8;
            c.scale = H / 2160 * 1.6; c.scaleRange = H / 2160 * 0.6;
            c.color = [UIColor colorWithHue:k / 6.0 saturation:0.8 brightness:1 alpha:1].CGColor;
            [cells addObject:c];
        }
        CAEmitterLayer *e = [CAEmitterLayer layer];
        e.emitterShape = kCAEmitterLayerLine;
        e.emitterPosition = CGPointMake(W / 2, -20);
        e.emitterSize = CGSizeMake(W, 1);
        e.emitterCells = cells;
        emitOnce(e, 1.5, 7);
    }
}

// --- Party: web server for guests ---
// Tiny HTTP/1.1 server on Network.framework: one request per connection, except /api/events, which stays
// open as a Server-Sent Events stream ("state" = now playing + queue; "line" = a lyric line just started).

static NSMutableArray *sseClients;   // nw_connection_t
static int artVersion;               // bumps on song change so guests reload /art.jpg

static NSData *jsonData(id o) { return [NSJSONSerialization dataWithJSONObject:o options:0 error:nil]; }

static dispatch_data_t ddata(NSData *d) { return dispatch_data_create(d.bytes, d.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT); }

static void reply(nw_connection_t c, int code, NSString *type, NSData *body) {
    body = body ?: [NSData data];
    NSMutableData *d = [[[NSString stringWithFormat:@"HTTP/1.1 %d %@\r\nContent-Type: %@\r\nContent-Length: %lu\r\n"
                          "Cache-Control: no-store\r\nConnection: close\r\n\r\n", code, code == 200 ? @"OK" : @"Error", type,
                          (unsigned long)body.length] dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [d appendData:body];
    nw_connection_send(c, ddata(d), NW_CONNECTION_FINAL_MESSAGE_CONTEXT, true, ^(nw_error_t e) { nw_connection_cancel(c); });
}

static void sseSend(nw_connection_t c, NSData *d) {
    nw_connection_send(c, ddata(d), NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, false, ^(nw_error_t e) {
        if (e) { [sseClients removeObject:c]; nw_connection_cancel(c); }
    });
}

static NSData *sseEvent(NSString *name, id obj) {
    NSMutableData *d = [[[NSString stringWithFormat:@"event: %@\ndata: ", name] dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [d appendData:jsonData(obj)];
    [d appendBytes:"\n\n" length:2];
    return d;
}

static void broadcast(NSString *name, id obj) {
    if (!sseClients.count) return;
    NSData *d = sseEvent(name, obj);
    for (nw_connection_t c in sseClients.copy) sseSend(c, d);
}

static NSArray *upcoming(void) {
    return [(partyNext ? @[partyNext] : @[]) arrayByAddingObjectsFromArray:partyQueue ?: @[]];
}

static NSDictionary *publicPick(NSDictionary *d) {
    NSMutableDictionary *m = d.mutableCopy;
    [m removeObjectsForKeys:@[@"uid"]];
    return m;
}

static NSDictionary *partyState(void) {
    // The pick already handed to Music is locked: it can no longer be withdrawn.
    NSMutableArray *queue = [NSMutableArray array];
    if (partyNext) { NSMutableDictionary *d = publicPick(partyNext).mutableCopy; d[@"locked"] = @YES; [queue addObject:d]; }
    for (NSDictionary *d in partyQueue) [queue addObject:publicPick(d)];   // picks pushed back by a 优先 carry their own locked flag
    NSString *sid = MPMusicPlayerController.systemMusicPlayer.nowPlayingItem.playbackStoreID ?: @"";
    return @{@"now": @{@"id": sid, @"title": songTitle, @"artist": songArtist, @"by": partyNow[@"by"] ?: @"", @"pid": partyNow[@"pid"] ?: @0,
                       @"art": art ? [NSString stringWithFormat:@"/art.jpg?v=%d", artVersion] : @""},
             @"mode": noSing ? @"nosing" : original ? @"original" : @"accompany",
             @"queue": queue};
}

// Redraw the TV queue and the phone line, and tell every guest.
static void partyRefresh(void) {
    NSArray *up = upcoming();
    partyLabel.text = partyURL ? [NSString stringWithFormat:@"派对 %@ · 排队 %lu 首\n切走本 App 派对会停 · 建议开“引导式访问”（设置›辅助功能）", [partyURL substringFromIndex:7], (unsigned long)up.count]
                               : @"派对：手机没连 Wi-Fi";
    if (tvQueue) {
        CGFloat H = tvQueue.superview.bounds.size.height;
        NSMutableAttributedString *s = [NSMutableAttributedString new];
        NSDictionary *head = @{NSFontAttributeName: [UIFont systemFontOfSize:H * 0.024 weight:UIFontWeightHeavy],
                               NSForegroundColorAttributeName: rgb(1, 0.82, 0.2)};
        NSDictionary *body = @{NSFontAttributeName: [UIFont systemFontOfSize:H * 0.03 weight:UIFontWeightBold],
                               NSForegroundColorAttributeName: UIColor.whiteColor};
        NSDictionary *who = @{NSFontAttributeName: [UIFont systemFontOfSize:H * 0.024 weight:UIFontWeightSemibold],
                              NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.6]};
        if (up.count) [s appendAttributedString:[[NSAttributedString alloc] initWithString:@"下一首\n" attributes:head]];
        for (NSUInteger k = 0; k < MIN(up.count, 3); k++) {
            [s appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%lu. %@", k + 1, up[k][@"title"]] attributes:body]];
            [s appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"   %@ 点\n", up[k][@"by"]] attributes:who]];
        }
        if (up.count > 3) [s appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"还有 %lu 首", up.count - 3] attributes:who]];
        tvQueue.attributedText = s;
        CGRect f = tvQueue.frame;
        f.size.height = [tvQueue sizeThatFits:CGSizeMake(f.size.width, CGFLOAT_MAX)].height;
        tvQueue.frame = f;
    }
    broadcast(@"state", partyState());
}

// Hand the next pick to Music. It goes right after the current song; when nothing is playing, it starts now.
static void feedParty(BOOL mayStart) {
    if (partyNext || !partyQueue.count) return;
    partyNext = partyQueue.firstObject;
    [partyQueue removeObjectAtIndex:0];
    prefetchLyrics(partyNext);
    if (partyNext[@"locked"]) return;   // pushed back by a 优先; it is already in Music's queue
    MPMusicPlayerController *p = MPMusicPlayerController.systemMusicPlayer;
    if (mayStart && p.playbackState != MPMusicPlaybackStatePlaying) {
        [p setQueueWithStoreIDs:@[partyNext[@"id"]]];
        [p play];
    } else {
        [p prependQueueDescriptor:[[MPMusicPlayerStoreQueueDescriptor alloc] initWithStoreIDs:@[partyNext[@"id"]]]];
    }
    L(@"party: %@ %@ (%@) for %@", mayStart && !playing ? @"start" : @"prepend", partyNext[@"title"], partyNext[@"id"], partyNext[@"by"]);
}

static void partySongChanged(MPMediaItem *it) {
    artVersion++;
    partySkipped = NO;
    partyNow = nil;
    if (partyNext && ([it.playbackStoreID isEqual:partyNext[@"id"]] || [it.title isEqual:partyNext[@"title"]])) {
        partyNow = partyNext;
        partyNext = nil;
        feedParty(NO);
    } else if (partyNext) {
        // Something else came on: the host played a song in Music, two skips landed at once, or the app was in
        // the background. Music may have dropped our picks, so hand the next one over again; picks pushed back
        // by a 优先 lose their lock and are handed over in turn. If Music came to a queued pick early, that pick is
        // playing now and leaves the queue.
        // ponytail: Music's queue can't be read, so a host song can push a pick back twice before it's dropped.
        NSUInteger k = [partyQueue indexOfObjectPassingTest:^BOOL(NSDictionary *d, NSUInteger n, BOOL *stop) {
            return [it.playbackStoreID isEqual:d[@"id"]] || [it.title isEqual:d[@"title"]]; }];
        if (k != NSNotFound) { partyNow = partyQueue[k]; [partyQueue removeObjectAtIndex:k]; }
        for (NSUInteger i = 0; i < partyQueue.count; i++) if (partyQueue[i][@"locked"]) {
            NSMutableDictionary *d = partyQueue[i].mutableCopy;
            [d removeObjectForKey:@"locked"];
            partyQueue[i] = d;
        }
        if (partyNext[@"retried"]) {   // handed over twice and Music still played something else: it can't play this one
            L(@"party: drop %@, Music played %@ instead again", partyNext[@"title"], it.title);
            partyNext = nil;
            feedParty(NO);
        } else {
            NSMutableDictionary *d = partyNext.mutableCopy;
            d[@"retried"] = @YES;
            partyNext = d;
            [MPMusicPlayerController.systemMusicPlayer prependQueueDescriptor:[[MPMusicPlayerStoreQueueDescriptor alloc] initWithStoreIDs:@[partyNext[@"id"]]]];
            L(@"party: re-prepend %@, Music played %@ instead", partyNext[@"title"], it.title);
        }
    }
    partyRefresh();
}

// String field from guest JSON, trimmed and cut to `max` characters.
static NSString *field(NSDictionary *j, NSString *k, NSUInteger max) {
    id v = j[k];
    if (![v isKindOfClass:NSString.class]) return @"";
    NSString *s = [v stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return s.length <= max ? s : [s substringWithRange:[s rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, max)]];
}

static NSDictionary *parseJSON(NSString *body) {
    id j = [NSJSONSerialization JSONObjectWithData:[body dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    return [j isKindOfClass:NSDictionary.class] ? j : nil;
}

// Catalog song resources -> {id, title, artist, art, dur} for the guest page.
static NSArray *songList(id songs) {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSDictionary *s in [songs isKindOfClass:NSArray.class] ? songs : @[]) {
        if (![s[@"type"] isEqual:@"songs"] || [seen containsObject:s[@"id"]]) continue;
        [seen addObject:s[@"id"]];
        NSDictionary *a = s[@"attributes"];
        NSString *artURL = [a[@"artwork"][@"url"] stringByReplacingOccurrencesOfString:@"{w}x{h}" withString:@"120x120"];
        [out addObject:@{@"id": s[@"id"] ?: @"", @"title": a[@"name"] ?: @"", @"artist": a[@"artistName"] ?: @"",
                         @"art": artURL ?: @"", @"dur": @([a[@"durationInMillis"] doubleValue] / 1000)}];
    }
    return out;
}

// 主人常听 (the host's recently played) and 排行榜 (Taiwan chart, kept to songs this storefront has). Cached 10 min.
static void loadRecs(void (^done)(NSDictionary *)) {
    static NSDictionary *cache;
    static NSDate *at;
    if (cache && -at.timeIntervalSinceNow < 600) { done(cache); return; }
    NSMutableDictionary *r = [NSMutableDictionary dictionaryWithDictionary:@{@"host": @[], @"charts": @[]}];
    __block int left = 2;
    void (^finish)(void) = ^{
        if (--left) return;
        if ([r[@"host"] count] || [r[@"charts"] count]) { cache = r; at = NSDate.date; }
        done(r);
    };
    [Catalog get:@"https://api.music.apple.com/v1/me/recent/played/tracks?types=songs&limit=30" done:^(NSInteger code, NSString *b) {
        r[@"host"] = songList(parseJSON(b)[@"data"]);
        L(@"party recs host %ld, %lu songs", (long)code, (unsigned long)[r[@"host"] count]);
        finish();
    }];
    [Catalog get:@"https://api.music.apple.com/v1/catalog/tw/charts?types=songs&limit=50" done:^(NSInteger code, NSString *b) {
        NSArray *chart = parseJSON(b)[@"results"][@"songs"];
        NSArray *ids = [[chart isKindOfClass:NSArray.class] ? chart.firstObject[@"data"] : nil valueForKey:@"id"];
        if (![ids isKindOfClass:NSArray.class] || !ids.count) { finish(); return; }
        [Catalog get:[@"https://api.music.apple.com/v1/catalog/{sf}/songs?ids=" stringByAppendingString:[ids componentsJoinedByString:@","]]
                done:^(NSInteger code2, NSString *b2) {
            // Keep the chart order; the ids lookup drops songs this storefront doesn't have.
            NSArray *have = songList(parseJSON(b2)[@"data"]);
            NSDictionary *byID = [NSDictionary dictionaryWithObjects:have forKeys:[have valueForKey:@"id"]];
            NSMutableArray *out = [NSMutableArray array];
            for (NSString *i in ids) if (byID[i]) [out addObject:byID[i]];
            r[@"charts"] = out;
            L(@"party recs charts %ld/%ld, %lu of %lu songs", (long)code, (long)code2, (unsigned long)out.count, (unsigned long)ids.count);
            finish();
        }];
    }];
}

static void searchSongs(NSString *q, void (^done)(NSArray *)) {
    q = [q substringToIndex:MIN(q.length, 60)];
    if (!q.length) { done(@[]); return; }
    NSCharacterSet *safe = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    NSString *url = [@"https://api.music.apple.com/v1/catalog/{sf}/search?types=songs&limit=25&term="
                     stringByAppendingString:[q stringByAddingPercentEncodingWithAllowedCharacters:safe]];
    [Catalog get:url done:^(NSInteger code, NSString *body) {
        NSArray *out = songList(parseJSON(body)[@"results"][@"songs"][@"data"]);
        L(@"party search \"%@\": %ld, %lu songs", q, (long)code, (unsigned long)out.count);
        done(out);
    }];
}

static void startEvents(nw_connection_t c) {
    if (sseClients.count >= 60) { reply(c, 503, @"text/plain", nil); return; }
    [sseClients addObject:c];
    sseSend(c, [@"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\n\r\nretry: 2000\n\n"
                dataUsingEncoding:NSUTF8StringEncoding]);
    sseSend(c, sseEvent(@"state", partyState()));
    // The guest never sends more; any read result means it went away.
    nw_connection_receive(c, 1, 1024, ^(dispatch_data_t d, nw_content_context_t x, bool complete, nw_error_t e) {
        [sseClients removeObject:c];
        nw_connection_cancel(c);
    });
}

static void handle(nw_connection_t c, NSString *method, NSString *target, NSData *body) {
    NSURLComponents *u = [NSURLComponents componentsWithString:target];
    NSString *path = u.path ?: @"";
    NSDictionary *j = [method isEqual:@"POST"] ? [NSJSONSerialization JSONObjectWithData:body options:0 error:nil] : nil;
    if (![j isKindOfClass:NSDictionary.class]) j = nil;
    NSString *by = field(j, @"by", 12), *uid = field(j, @"uid", 40);
    if (!by.length) by = @"朋友";
    NSData *ok = jsonData(@{@"ok": @YES});
    if ([path isEqual:@"/"]) {
        static NSData *page;
        page = page ?: [NSData dataWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"party" ofType:@"html"]];
        reply(c, 200, @"text/html; charset=utf-8", page);
    } else if ([path isEqual:@"/art.jpg"]) {
        reply(c, art ? 200 : 404, @"image/jpeg", art ? UIImageJPEGRepresentation(art, 0.8) : nil);
    } else if ([path isEqual:@"/api/events"]) {
        startEvents(c);
    } else if ([path isEqual:@"/api/recs"]) {
        loadRecs(^(NSDictionary *r) {
            // 今晚热门: most picked first, then most recent.
            NSArray *hot = [tonight sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [b[@"n"] compare:a[@"n"]];
            }];
            NSMutableDictionary *o = r.mutableCopy;
            o[@"tonight"] = [hot subarrayWithRange:NSMakeRange(0, MIN(hot.count, 30))];
            reply(c, 200, @"application/json", jsonData(o));
        });
    } else if ([path isEqual:@"/api/search"]) {
        NSString *q;
        for (NSURLQueryItem *i in u.queryItems) if ([i.name isEqual:@"q"]) q = i.value;
        searchSongs(q, ^(NSArray *songs) { reply(c, 200, @"application/json", jsonData(songs)); });
    } else if ([path isEqual:@"/api/queue"] && j) {
        NSString *sid = field(j, @"id", 20), *artURL = field(j, @"art", 400), *title = field(j, @"title", 80);
        if (!sid.length || [sid rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location != NSNotFound
            || partyQueue.count >= 50) {
            reply(c, 400, @"text/plain", nil);
            return;
        }
        [partyQueue addObject:@{@"id": sid, @"title": title, @"artist": field(j, @"artist", 80), @"by": by, @"uid": uid,
                                @"pid": @(++pickCount), @"dur": [j[@"dur"] isKindOfClass:NSNumber.class] ? j[@"dur"] : @0, @"art": [artURL hasPrefix:@"https://"] ? artURL : @""}];
        NSNumber *pid = partyQueue.lastObject[@"pid"];
        danmaku(by, [NSString stringWithFormat:@"点了《%@》", title], rgb(1, 0.82, 0.2));
        NSUInteger t = [tonight indexOfObjectPassingTest:^BOOL(NSDictionary *d, NSUInteger k, BOOL *stop) { return [d[@"id"] isEqual:sid]; }];
        NSMutableDictionary *h = t != NSNotFound ? tonight[t] : [@{@"id": sid, @"title": title, @"artist": partyQueue.lastObject[@"artist"],
            @"art": partyQueue.lastObject[@"art"], @"dur": [j[@"dur"] isKindOfClass:NSNumber.class] ? j[@"dur"] : @0, @"n": @0} mutableCopy];
        if (t != NSNotFound) [tonight removeObjectAtIndex:t];
        h[@"n"] = @([h[@"n"] intValue] + 1);
        [tonight insertObject:h atIndex:0];
        feedParty(YES);
        partyRefresh();
        reply(c, 200, @"application/json", jsonData(@{@"ok": @YES, @"pos": @(upcoming().count), @"pid": pid}));
    } else if ([path isEqual:@"/api/control"] && j) {
        // Guest remote. Each action names its target, so two guests tapping at once don't skip twice.
        NSString *action = field(j, @"action", 10), *value = field(j, @"value", 80);
        if ([action isEqual:@"skip"] && [value isEqual:songTitle] && !partySkipped) {
            partySkipped = YES;   // two taps can land before the song changes; only the first one skips
            [MPMusicPlayerController.systemMusicPlayer skipToNextItem];
            danmaku(by, [NSString stringWithFormat:@"切掉了《%@》", songTitle], rgb(1, 0.27, 0.23));
        } else if ([action isEqual:@"mode"] && !noSing && original != [value isEqual:@"original"]) {
            original = !original;
            sendVocals();
            updateModeUI();
            danmaku(by, original ? @"切到原唱" : @"切到伴唱", original ? UIColor.systemOrangeColor : UIColor.systemPinkColor);
        } else if ([action isEqual:@"remove"] || [action isEqual:@"top"]) {
            // Picks Music doesn't have yet; value is the pick's pid. Anyone may 优先 (the TV says who), only the
            // picker may 撤回.
            BOOL topping = [action isEqual:@"top"];
            NSUInteger i = [partyQueue indexOfObjectPassingTest:^BOOL(NSDictionary *d, NSUInteger k, BOOL *stop) {
                return [[d[@"pid"] stringValue] isEqual:value] && !d[@"locked"] && (topping || (uid.length && [d[@"uid"] isEqual:uid]));
            }];
            if (i == NSNotFound) {
                reply(c, 409, @"application/json", jsonData(@{@"msg": topping ? @"这首已经轮到了" : @"这首已经轮到了，或者不是你点的"}));
                return;
            }
            if (!topping) {
                [partyQueue removeObjectAtIndex:i];
            } else if (partyNext) {
                // 优先: hand this pick to Music right after the current song. The old next pick stays in
                // Music's queue behind it, so it moves back into partyQueue as locked.
                NSMutableDictionary *d = partyQueue[i].mutableCopy;
                [partyQueue removeObjectAtIndex:i];
                NSMutableDictionary *old = partyNext.mutableCopy;
                old[@"locked"] = @YES;
                [partyQueue insertObject:old atIndex:0];
                partyNext = d;
                prefetchLyrics(d);
                [MPMusicPlayerController.systemMusicPlayer prependQueueDescriptor:[[MPMusicPlayerStoreQueueDescriptor alloc] initWithStoreIDs:@[d[@"id"]]]];
                danmaku(by, [NSString stringWithFormat:@"把《%@》顶到下一首", d[@"title"]], rgb(1, 0.82, 0.2));
            }
            partyRefresh();
        }
        L(@"party control %@ %@ by %@", action, value, by);
        reply(c, 200, @"application/json", ok);
    } else if ([path isEqual:@"/api/cheer"] && j) {
        NSString *type = field(j, @"type", 10), *value = field(j, @"value", 30);
        if ([type isEqual:@"emoji"] && value.length <= 12) floatEmoji(value, 0);
        else if ([type isEqual:@"text"] && value.length) danmaku(by, value, [UIColor colorWithHue:drand48() saturation:0.6 brightness:1 alpha:1]);
        else if ([type isEqual:@"fx"]) burst(value);
        reply(c, 200, @"application/json", ok);
    } else {
        reply(c, 404, @"text/plain", [@"not found" dataUsingEncoding:NSUTF8StringEncoding]);
    }
}

// Reads until the end of the headers plus Content-Length bytes of body (64 KB at most), then handles it.
static void readRequest(nw_connection_t c, NSMutableData *buf) {
    nw_connection_receive(c, 1, 65536, ^(dispatch_data_t content, nw_content_context_t ctx, bool complete, nw_error_t err) {
        if (content) [buf appendData:(NSData *)content];
        BOOL more = !err && !complete && buf.length < 70000;
        NSRange end = [buf rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4] options:0 range:NSMakeRange(0, buf.length)];
        if (end.location == NSNotFound) { more ? readRequest(c, buf) : nw_connection_cancel(c); return; }
        NSString *head = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, end.location)] encoding:NSUTF8StringEncoding];
        NSArray *hl = [head componentsSeparatedByString:@"\r\n"];
        NSArray *rl = [hl.firstObject componentsSeparatedByString:@" "];
        NSInteger len = 0;
        for (NSString *h in hl) if ([h.lowercaseString hasPrefix:@"content-length:"]) len = [h substringFromIndex:15].integerValue;
        NSUInteger start = NSMaxRange(end);
        if (rl.count < 2 || len < 0 || len > 65536) { nw_connection_cancel(c); return; }
        if (buf.length - start < (NSUInteger)len) { more ? readRequest(c, buf) : nw_connection_cancel(c); return; }
        handle(c, rl[0], rl[1], [buf subdataWithRange:NSMakeRange(start, len)]);
    });
}

static void startServer(void) {
    nw_parameters_t params = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_parameters_set_reuse_local_address(params, true);
    nw_listener_t l = nw_listener_create_with_port("8080", params);
    nw_listener_set_queue(l, dispatch_get_main_queue());
    nw_listener_set_new_connection_handler(l, ^(nw_connection_t c) {
        nw_connection_set_queue(c, dispatch_get_main_queue());
        nw_connection_start(c);
        readRequest(c, [NSMutableData data]);
    });
    nw_listener_set_state_changed_handler(l, ^(nw_listener_state_t s, nw_error_t e) {
        L(@"party server state %d%@", s, e ? [NSString stringWithFormat:@" error %d", nw_error_get_error_code(e)] : @"");
        if (s == nw_listener_state_failed) {   // e.g. after the app was suspended: start over
            nw_listener_cancel(l);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ startServer(); });
        }
    });
    nw_listener_start(l);
}

static NSString *wifiAddress(void) {
    struct ifaddrs *list;
    NSString *ip;
    if (getifaddrs(&list)) return nil;
    for (struct ifaddrs *a = list; a; a = a->ifa_next)
        if (a->ifa_addr && a->ifa_addr->sa_family == AF_INET && !strcmp(a->ifa_name, "en0")) {
            char s[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &((struct sockaddr_in *)a->ifa_addr)->sin_addr, s, sizeof s);
            ip = @(s);
        }
    freeifaddrs(list);
    return ip;
}

// Every 5 s: follow Wi-Fi address changes and keep idle event streams alive (a dead guest fails the send).
static void partyTick(void) {
    NSString *ip = wifiAddress(), *url = ip ? [NSString stringWithFormat:@"http://%@:8080", ip] : nil;
    if (url != partyURL && ![url isEqual:partyURL]) {
        partyURL = url;
        L(@"party at %@", url ?: @"(no Wi-Fi)");
        showQR();
        partyRefresh();
    }
    NSData *ping = [@":\n\n" dataUsingEncoding:NSUTF8StringEncoding];
    for (nw_connection_t c in sseClients.copy) sseSend(c, ping);
}

// --- Scenes ---

@interface TVScene : UIResponder <UIWindowSceneDelegate>
@property (nonatomic) UIWindow *window;
@end

@implementation TVScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)opts {
    UIWindowScene *ws = (UIWindowScene *)scene;
    CGRect b = ws.effectiveGeometry.coordinateSpace.bounds;
    CGFloat W = b.size.width, H = b.size.height;
    self.window = tvWindow = [[UIWindow alloc] initWithWindowScene:ws];
    UIViewController *vc = [UIViewController new];
    UIView *v = vc.view;
    v.frame = b;
    v.backgroundColor = rgb(0.03, 0.01, 0.08);

    // Backdrop: the album art blown up from a tiny copy, dimmed, slowly zooming.
    tvBackdrop = [UIImageView new];
    tvBackdrop.contentMode = UIViewContentModeScaleAspectFill;
    tvBackdrop.alpha = 0.5;
    fill(tvBackdrop, v);
    kenBurns(tvBackdrop.layer, 36);
    UIView *dim = [UIView new];
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    fill(dim, v);

    // Stage light: soft beams from above the screen, swinging; they flare on each line start.
    tvRays = [CAGradientLayer layer];
    tvRays.type = kCAGradientLayerConic;
    tvRays.startPoint = CGPointMake(0.5, 0.5); tvRays.endPoint = CGPointMake(0.5, 0);
    NSMutableArray *rc = [NSMutableArray array];
    for (int k = 0; k < 72; k++) [rc addObject:(id)[UIColor colorWithWhite:1 alpha:k % 3 ? 0 : 0.6].CGColor];
    [rc addObject:rc[0]];
    tvRays.colors = rc;
    tvRays.bounds = CGRectMake(0, 0, W * 2.4, W * 2.4);
    tvRays.position = CGPointMake(W / 2, -H * 0.35);
    CABasicAnimation *swing = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    swing.fromValue = @(-0.2); swing.toValue = @0.2;
    swing.duration = 11; swing.autoreverses = YES; swing.repeatCount = HUGE_VALF;
    swing.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [tvRays addAnimation:swing forKey:nil];
    [v.layer addSublayer:tvRays];

    // Glow blobs in the artwork's colours, drifting on slow ellipses.
    NSMutableArray *blobs = [NSMutableArray array];
    for (int k = 0; k < 4; k++) {
        CAGradientLayer *g = radial(H * 0.9, nil);
        g.position = CGPointMake(W * (0.15 + 0.23 * k), H * 0.5);
        CGPathRef path = CGPathCreateWithEllipseInRect(CGRectMake(W * (0.02 + 0.2 * k), H * (0.1 + 0.15 * (k % 2)), W * 0.4, H * 0.6), NULL);
        CAKeyframeAnimation *drift = [CAKeyframeAnimation animationWithKeyPath:@"position"];
        drift.path = path;
        CGPathRelease(path);
        drift.duration = 19 + 7 * k;
        drift.timeOffset = k * 6;
        drift.repeatCount = HUGE_VALF;
        drift.calculationMode = kCAAnimationPaced;
        [g addAnimation:drift forKey:nil];
        [v.layer addSublayer:g];
        [blobs addObject:g];
    }
    tvBlobs = blobs;

    // Embers rising from the bottom edge; a burst on each line start.
    CAEmitterCell *spark = [CAEmitterCell emitterCell];
    spark.name = @"spark";
    spark.contents = dotImage();
    spark.birthRate = 30; spark.lifetime = 7;
    spark.velocity = H * 0.12; spark.velocityRange = H * 0.08;
    spark.emissionLongitude = -M_PI_2; spark.emissionRange = 0.35;
    spark.scale = H / 2160 * 0.9; spark.scaleRange = H / 2160 * 0.6;
    spark.alphaSpeed = -0.14;
    spark.color = UIColor.whiteColor.CGColor;
    spark.redRange = spark.greenRange = spark.blueRange = 0.3;
    tvSparks = [CAEmitterLayer layer];
    tvSparks.emitterShape = kCAEmitterLayerLine;
    tvSparks.emitterPosition = CGPointMake(W / 2, H + 10);
    tvSparks.emitterSize = CGSizeMake(W, 1);
    tvSparks.emitterCells = @[spark];
    tvSparks.birthRate = 0;
    [v.layer addSublayer:tvSparks];

    // Spinning disc of coloured arcs behind the lyrics, each ring at its own speed and direction.
    CGFloat R = H * 0.46;
    tvRing = [CALayer layer];
    tvRing.frame = CGRectMake(W / 2 - R, H * 0.5 - R, 2 * R, 2 * R);
    NSMutableArray *arcs = [NSMutableArray array];
    srand48(7);
    for (int k = 0; k < 11; k++) {
        CAShapeLayer *a = [CAShapeLayer layer];
        a.frame = tvRing.bounds;
        CGFloat r = R * (0.18 + 0.075 * k);
        a.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(R, R) radius:r startAngle:0 endAngle:2 * M_PI clockwise:YES].CGPath;
        a.fillColor = nil;
        a.lineWidth = H * (0.008 + 0.022 * drand48());
        a.lineCap = kCALineCapRound;
        a.strokeStart = 0;
        a.strokeEnd = 0.2 + 0.55 * drand48();
        CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        spin.byValue = @(k % 2 ? 2 * M_PI : -2 * M_PI);
        spin.duration = 9 + 25 * drand48();
        spin.repeatCount = HUGE_VALF;
        [a addAnimation:spin forKey:nil];
        [tvRing addSublayer:a];
        [arcs addObject:a];
    }
    tvArcs = arcs;
    [v.layer addSublayer:tvRing];

    // Spectrum: rainbow block bars on a baseline, with a faint mirror below.
    CGFloat period = round(H * 0.019), specW = W * 0.9, baseY = H * 0.82;
    tvSpecH = period * 16;
    CALayer *up = [CALayer layer], *down = [CALayer layer];
    up.frame = CGRectMake(W * 0.05, baseY - tvSpecH, specW, tvSpecH);
    down.frame = CGRectMake(W * 0.05, baseY + period * 0.3, specW, tvSpecH * 0.45);
    up.opacity = 0.75; down.opacity = 0.22;
    // Mask of horizontal stripes cuts the bars into blocks, like the LED meters on a KTV box.
    UIImage *stripe = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(4, period)] imageWithActions:^(UIGraphicsImageRendererContext *c) {
        [UIColor.whiteColor setFill];
        UIRectFill(CGRectMake(0, 0, 4, period * 0.78));
    }];
    CALayer *blocks = [CALayer layer];
    blocks.frame = up.bounds;
    blocks.backgroundColor = [UIColor colorWithPatternImage:stripe].CGColor;
    up.mask = blocks;
    NSMutableArray *bars = [NSMutableArray array], *caps = [NSMutableArray array], *refl = [NSMutableArray array];
    CGFloat step = specW / (CGFloat)kBars;
    for (int k = 0; k < kBars; k++) {
        UIColor *c = [UIColor colorWithHue:0.83 * k / (kBars - 1) saturation:0.8 brightness:1 alpha:1];
        CAGradientLayer *bar = [CAGradientLayer layer];
        bar.colors = @[(id)[UIColor colorWithHue:0.83 * k / (kBars - 1) saturation:0.35 brightness:1 alpha:1].CGColor, (id)c.CGColor];
        bar.frame = CGRectMake(k * step + step * 0.1, tvSpecH, step * 0.8, 0);
        CALayer *capL = [CALayer layer];
        capL.backgroundColor = [UIColor colorWithWhite:1 alpha:0.9].CGColor;
        capL.frame = CGRectMake(bar.frame.origin.x, tvSpecH, step * 0.8, 0);
        CALayer *mirror = [CALayer layer];
        mirror.backgroundColor = c.CGColor;
        mirror.frame = CGRectMake(bar.frame.origin.x, 0, step * 0.8, 0);
        for (CALayer *l in @[bar, capL, mirror]) l.actions = @{@"bounds": NSNull.null, @"position": NSNull.null};
        [up addSublayer:bar]; [up addSublayer:capL]; [down addSublayer:mirror];
        [bars addObject:bar]; [caps addObject:capL]; [refl addObject:mirror];
    }
    tvBars = bars; tvCaps = caps; tvRefl = refl;
    [v.layer addSublayer:up];
    [v.layer addSublayer:down];

    tvLyrics = [UIView new];
    fill(tvLyrics, v);
    tvSize = H * 0.09;
    tvMaxWidth = W * 0.86;
    KTVLine *top = [KTVLine new], *bottom = [KTVLine new];
    top.anchor = CGPointMake(W * 0.05, H * 0.47);
    bottom.anchor = CGPointMake(W * 0.95, H * 0.66);
    bottom.rightAligned = YES;
    [tvLyrics addSubview:top]; [tvLyrics addSubview:bottom];
    tvSlots = @[top, bottom];
    tvDots = label(H * 0.05, UIFontWeightHeavy, rgb(1, 0.82, 0.2));
    tvDots.frame = CGRectMake(W * 0.06, H * 0.38, W * 0.3, H * 0.08);
    [tvLyrics addSubview:tvDots];

    // Header: artwork, title, artist. 原唱/伴唱 badge top-right.
    CGFloat side = H * 0.12;
    tvArt = [[UIImageView alloc] initWithFrame:CGRectMake(W * 0.04, H * 0.05, side, side)];
    tvArt.layer.cornerRadius = side * 0.12;
    tvArt.clipsToBounds = YES;
    tvArt.contentMode = UIViewContentModeScaleAspectFill;
    tvArt.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
    tvTitle = label(H * 0.045, UIFontWeightHeavy, UIColor.whiteColor);
    tvTitle.frame = CGRectMake(W * 0.04 + side * 1.2, H * 0.05, W * 0.6, side * 0.58);
    tvTitle.text = songTitle;
    tvArtist = label(H * 0.03, UIFontWeightSemibold, [UIColor colorWithWhite:1 alpha:0.7]);
    tvArtist.frame = CGRectMake(W * 0.04 + side * 1.2, H * 0.05 + side * 0.58, W * 0.6, side * 0.42);
    tvArtist.text = songArtist;
    tvMode = label(H * 0.032, UIFontWeightHeavy, UIColor.whiteColor);
    tvMode.textAlignment = NSTextAlignmentCenter;
    tvMode.frame = CGRectMake(0, H * 0.065, 0, 0);
    tvMode.layer.cornerRadius = H * 0.022;
    tvMode.clipsToBounds = YES;
    for (UIView *x in @[tvArt, tvTitle, tvArtist, tvMode]) [v addSubview:x];

    // Song progress along the bottom, with a glowing head.
    CGFloat barH = H * 0.007;
    tvBarWidth = W * 0.9;
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(W * 0.05, H * 0.935, tvBarWidth, barH)];
    bar.backgroundColor = [UIColor colorWithWhite:1 alpha:0.15];
    bar.layer.cornerRadius = barH / 2;
    tvBarFill = [CAGradientLayer layer];
    tvBarFill.startPoint = CGPointMake(0, 0.5); tvBarFill.endPoint = CGPointMake(1, 0.5);
    tvBarFill.cornerRadius = barH / 2;
    [bar.layer addSublayer:tvBarFill];
    tvBarHead = radial(H * 0.05, @[(id)UIColor.whiteColor.CGColor, (id)[rgb(1, 0.8, 0.3) colorWithAlphaComponent:0.5].CGColor,
                                   (id)UIColor.clearColor.CGColor]);
    [bar.layer addSublayer:tvBarHead];
    [v addSubview:bar];

    // Intro card: big artwork glowing in its own colour, title and artist underneath.
    tvIntro = [UIView new];
    fill(tvIntro, v);
    tvIntro.alpha = 0;
    CGFloat S = H * 0.44;
    tvIntroBox = [[UIView alloc] initWithFrame:CGRectMake((W - S) / 2, H * 0.12, S, S)];
    tvIntroBox.layer.shadowRadius = H * 0.06;
    tvIntroBox.layer.shadowOpacity = 0.9;
    tvIntroBox.layer.shadowOffset = CGSizeZero;
    tvIntroBox.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:tvIntroBox.bounds cornerRadius:S * 0.06].CGPath;
    tvIntroArt = [[UIImageView alloc] initWithFrame:tvIntroBox.bounds];
    tvIntroArt.contentMode = UIViewContentModeScaleAspectFill;
    tvIntroArt.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
    tvIntroArt.layer.cornerRadius = S * 0.06;
    tvIntroArt.clipsToBounds = YES;
    [tvIntroBox addSubview:tvIntroArt];
    tvIntroTitle = label(H * 0.08, UIFontWeightHeavy, UIColor.whiteColor);
    tvIntroTitle.frame = CGRectMake(W * 0.1, H * 0.12 + S + H * 0.04, W * 0.8, H * 0.1);
    tvIntroArtist = label(H * 0.045, UIFontWeightSemibold, [UIColor colorWithWhite:1 alpha:0.75]);
    tvIntroArtist.frame = CGRectMake(W * 0.1, H * 0.12 + S + H * 0.15, W * 0.8, H * 0.07);
    for (UILabel *l in @[tvIntroTitle, tvIntroArtist]) l.textAlignment = NSTextAlignmentCenter;
    for (UIView *x in @[tvIntroBox, tvIntroTitle, tvIntroArtist]) [tvIntro addSubview:x];

    // Party: QR code top-right under the badge, next picks under the header, effects on top of everything.
    CGFloat qs = H * 0.15, pad = H * 0.012;
    UIView *qrBox = [[UIView alloc] initWithFrame:CGRectMake(W * 0.96 - qs - 2 * pad, H * 0.14, qs + 2 * pad, qs + 2 * pad)];
    qrBox.backgroundColor = UIColor.whiteColor;
    qrBox.layer.cornerRadius = pad * 1.5;
    tvQR = [[UIImageView alloc] initWithFrame:CGRectInset(qrBox.bounds, pad, pad)];
    tvQR.layer.magnificationFilter = kCAFilterNearest;
    [qrBox addSubview:tvQR];
    tvQRLabel = label(H * 0.024, UIFontWeightBold, UIColor.whiteColor);
    tvQRLabel.numberOfLines = 2;
    tvQRLabel.textAlignment = NSTextAlignmentCenter;
    tvQRLabel.frame = CGRectMake(CGRectGetMidX(qrBox.frame) - H * 0.15, CGRectGetMaxY(qrBox.frame) + pad, H * 0.3, H * 0.065);
    tvQueue = [UILabel new];
    tvQueue.numberOfLines = 0;
    tvQueue.frame = CGRectMake(W * 0.04, H * 0.2, W * 0.55, 0);
    for (UIView *x in @[qrBox, tvQRLabel, tvQueue]) [v addSubview:x];
    tvFx = [UIView new];
    fill(tvFx, v);

    self.window.rootViewController = vc;
    self.window.hidden = NO;
    updateModeUI();
    applyArt();
    showQR();
    partyRefresh();
    shown = -2;
    if (songKey) showIntro();
    L(@"TV connected %.0fx%.0f", W, H);
}

- (void)sceneDidDisconnect:(UIScene *)scene {
    tvSlots = nil; tvLyrics = nil; tvIntro = nil; tvIntroBox = nil;
    tvTitle = nil; tvArtist = nil; tvDots = nil; tvMode = nil; tvIntroTitle = nil; tvIntroArtist = nil;
    tvArt = nil; tvBackdrop = nil; tvIntroArt = nil; tvBlobs = nil; tvRays = nil; tvBarFill = nil; tvBarHead = nil;
    tvSparks = nil; tvWindow = nil; tvBars = nil; tvCaps = nil; tvRefl = nil; tvRing = nil; tvArcs = nil;
    tvFx = nil; tvQR = nil; tvQRLabel = nil; tvQueue = nil;
    introUp = NO;
    L(@"TV disconnected");
}
@end

@interface PhoneScene : UIResponder <UIWindowSceneDelegate>
@property (nonatomic) UIWindow *window;
@end

@implementation PhoneScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)opts {
    self.window = phoneWindow = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    UIViewController *vc = [UIViewController new];
    UIView *root = vc.view;
    root.backgroundColor = rgb(0.06, 0.03, 0.12);
    MPMusicPlayerController *p = MPMusicPlayerController.systemMusicPlayer;

    // Backdrop: album art under a dark blur, slowly zooming.
    phoneBackdrop = [UIImageView new];
    phoneBackdrop.contentMode = UIViewContentModeScaleAspectFill;
    fill(phoneBackdrop, root);
    kenBurns(phoneBackdrop.layer, 30);
    fill([[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]], root);
    UIView *shade = [UIView new];   // keeps pale covers from washing the console out
    shade.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    fill(shade, root);

    // Artwork card glowing in its own colour.
    CGFloat side = 200;
    phoneArtBox = [UIView new];
    phoneArtBox.translatesAutoresizingMaskIntoConstraints = NO;
    phoneArtBox.layer.shadowRadius = 30;
    phoneArtBox.layer.shadowOpacity = 0.8;
    phoneArtBox.layer.shadowOffset = CGSizeMake(0, 10);
    phoneArtBox.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, side, side) cornerRadius:18].CGPath;
    phoneArt = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, side, side)];
    phoneArt.contentMode = UIViewContentModeScaleAspectFill;
    phoneArt.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
    phoneArt.layer.cornerRadius = 18;
    phoneArt.layer.cornerCurve = kCACornerCurveContinuous;
    phoneArt.clipsToBounds = YES;
    [phoneArtBox addSubview:phoneArt];
    UIView *artRow = [UIView new];
    [artRow addSubview:phoneArtBox];
    [NSLayoutConstraint activateConstraints:@[
        [artRow.heightAnchor constraintEqualToConstant:side],
        [phoneArtBox.widthAnchor constraintEqualToConstant:side], [phoneArtBox.heightAnchor constraintEqualToConstant:side],
        [phoneArtBox.centerXAnchor constraintEqualToAnchor:artRow.centerXAnchor],
        [phoneArtBox.centerYAnchor constraintEqualToAnchor:artRow.centerYAnchor]]];

    phoneTitle = label(24, UIFontWeightHeavy, UIColor.whiteColor);
    phoneArtist = label(17, UIFontWeightSemibold, [UIColor colorWithWhite:1 alpha:0.6]);
    for (UILabel *l in @[phoneTitle, phoneArtist]) l.textAlignment = NSTextAlignmentCenter;
    UIStackView *names = stack(@[phoneTitle, phoneArtist], UILayoutConstraintAxisVertical, 2);

    phoneLyric = [UILabel new];
    phoneLyric.numberOfLines = 0;
    phoneLyric.adjustsFontSizeToFitWidth = YES;
    phoneLyric.minimumScaleFactor = 0.6;
    phoneLyric.clipsToBounds = YES;   // the push transition slides inside the label
    [phoneLyric setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisVertical];
    [phoneLyric.heightAnchor constraintGreaterThanOrEqualToConstant:76].active = YES;

    // Song position; drag to seek.
    seekSlider = slider(1, 0, UIColor.whiteColor, ^(float f) {
        p.currentPlaybackTime = f;
        sampleT = f; sampleWall = CACurrentMediaTime();
    });
    seekSlider.continuous = NO;
    [seekSlider setThumbImage:[[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(14, 14)] imageWithActions:^(UIGraphicsImageRendererContext *c) {
        [UIColor.whiteColor setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, 14, 14)] fill];
    }] forState:UIControlStateNormal];
    UIFont *digits = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
    phoneElapsed = label(12, UIFontWeightSemibold, [UIColor colorWithWhite:1 alpha:0.55]);
    phoneRemain = label(12, UIFontWeightSemibold, [UIColor colorWithWhite:1 alpha:0.55]);
    phoneElapsed.font = phoneRemain.font = digits;
    phoneRemain.textAlignment = NSTextAlignmentRight;
    UIStackView *progress = stack(@[seekSlider, stack(@[phoneElapsed, phoneRemain], UILayoutConstraintAxisHorizontal, 0)],
                                  UILayoutConstraintAxisVertical, 0);

    UIButton *restart = iconButton(@"重唱", @"arrow.counterclockwise", ^{ [p skipToBeginning]; [p play]; });
    playButton = button(@"", @"play.fill", UIColor.whiteColor, 76, ^{ playing ? [p pause] : [p play]; });
    UIButtonConfiguration *pc = playButton.configuration;
    pc.baseForegroundColor = UIColor.blackColor;
    pc.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:30 weight:UIImageSymbolWeightBold];
    playButton.configuration = pc;
    [playButton.widthAnchor constraintEqualToConstant:76].active = YES;
    UIButton *next = iconButton(@"切歌", @"forward.end.fill", ^{ [p skipToNextItem]; });
    UIStackView *transport = stack(@[restart, playButton, next], UILayoutConstraintAxisHorizontal, 0);
    transport.distribution = UIStackViewDistributionEqualSpacing;
    transport.alignment = UIStackViewAlignmentCenter;
    transport.layoutMarginsRelativeArrangement = YES;
    transport.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(0, 24, 0, 24);

    modeButton = button(@"", @"music.mic", UIColor.systemPinkColor, 60, ^{
        original = !original;
        sendVocals();
        updateModeUI();
        L(@"mode -> %@", original ? @"原唱" : @"伴唱");
    });
    UIButtonConfiguration *mc = modeButton.configuration;
    mc.titleAlignment = UIButtonConfigurationTitleAlignmentCenter;
    mc.subtitleTextAttributesTransformer = ^NSDictionary *(NSDictionary *a) {
        NSMutableDictionary *m = a.mutableCopy;
        m[NSFontAttributeName] = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        m[NSForegroundColorAttributeName] = [UIColor colorWithWhite:1 alpha:0.8];
        return m;
    };
    modeButton.configuration = mc;

    vocalLabel = label(14, UIFontWeightSemibold, [UIColor colorWithWhite:1 alpha:0.75]);
    vocalSlider = slider(99, vocalLevel, UIColor.systemPinkColor, ^(float f) {
        int v = (int)lroundf(f);
        if (v == vocalLevel && !original) return;
        vocalLevel = v;
        original = NO;   // moving the slider means 伴唱
        sendVocals();
        updateModeUI();
    });
    vocalSlider.minimumValueImage = [UIImage systemImageNamed:@"speaker.fill"];
    vocalSlider.maximumValueImage = [UIImage systemImageNamed:@"speaker.wave.3.fill"];
    vocalSlider.tintColor = [UIColor colorWithWhite:1 alpha:0.6];
    vocalSlider.minimumTrackTintColor = UIColor.systemPinkColor;
    UIView *vocalCard = card(stack(@[vocalLabel, vocalSlider], UILayoutConstraintAxisVertical, 6));

    logText = logText ?: [NSMutableString string];
    logView = [UITextView new];
    logView.editable = NO;
    logView.hidden = YES;
    logView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
    logView.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    logView.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    logView.text = logText;
    [logView.heightAnchor constraintEqualToConstant:160].active = YES;
    UIButton *logToggle = [UIButton systemButtonWithPrimaryAction:[UIAction actionWithTitle:@"日志" image:nil identifier:nil
                                                                                    handler:^(UIAction *a) { logView.hidden = !logView.hidden; }]];
    logToggle.tintColor = [UIColor colorWithWhite:1 alpha:0.3];

    // Per-song lyric timing and LRCLIB version, remembered in NSUserDefaults.
    void (^nudge)(double) = ^(double d) {
        lyricsOffset = round((lyricsOffset + d) * 10) / 10;
        [NSUserDefaults.standardUserDefaults setDouble:lyricsOffset forKey:songPref(@"offset")];
        shown = -2;
        updateSyncUI();
    };
    UIButton *earlier = iconButton(@"提前", @"backward.fill", ^{ nudge(0.5); });
    UIButton *later = iconButton(@"延后", @"forward.fill", ^{ nudge(-0.5); });
    versionButton = iconButton(@"换版本", @"arrow.triangle.2.circlepath", ^{
        showCandidate((pick + 1) % candidates.count);
        [NSUserDefaults.standardUserDefaults setObject:[candidates[pick][@"id"] description] forKey:songPref(@"lrc")];
    });
    syncLabel = label(13, UIFontWeightSemibold, [UIColor colorWithWhite:1 alpha:0.8]);
    syncLabel.numberOfLines = 2;
    syncLabel.textAlignment = NSTextAlignmentCenter;
    UIStackView *syncRow = stack(@[earlier, syncLabel, later, versionButton], UILayoutConstraintAxisHorizontal, 0);
    syncRow.distribution = UIStackViewDistributionEqualSpacing;
    syncRow.alignment = UIStackViewAlignmentCenter;
    UIView *syncCard = card(syncRow);

    partyLabel = label(12, UIFontWeightSemibold, [UIColor colorWithWhite:1 alpha:0.6]);
    partyLabel.numberOfLines = 2;
    UIStackView *bottomRow = stack(@[partyLabel, logToggle], UILayoutConstraintAxisHorizontal, 8);
    bottomRow.distribution = UIStackViewDistributionFill;
    [logToggle setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *main = stack(@[artRow, names, phoneLyric, progress, transport, modeButton, vocalCard, syncCard, bottomRow, logView],
                              UILayoutConstraintAxisVertical, 14);
    [main setCustomSpacing:20 afterView:artRow];
    pin(main, root);

    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    updateModeUI();
    applyArt();
    shown = -2;
    songKey = nil;  // redraw the title on the new labels
    partyRefresh();
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    app.idleTimerDisabled = YES;
    logText = [NSMutableString string];
    loadMR();
    sendVocals();  // start in 伴唱
    // Which CJK faces this iOS has, in case a heavier lyric font is wanted.
    NSMutableArray *cjk = [NSMutableArray array];
    for (NSString *fam in UIFont.familyNames)
        if ([fam rangeOfString:@"PingFang|Hiragino|Hei|Song|Kai|Yuan|Ming" options:NSRegularExpressionSearch].location != NSNotFound)
            [cjk addObjectsFromArray:[UIFont fontNamesForFamilyName:fam]];
    L(@"CJK fonts: %@", [cjk componentsJoinedByString:@" "]);
    // Test hook: `devicectl ... launch <bundle id> -- -playStoreID <id>` starts that catalog song in Music.
    NSString *play = [NSUserDefaults.standardUserDefaults stringForKey:@"playStoreID"];
    if (play.length) {
        [MPMusicPlayerController.systemMusicPlayer setQueueWithStoreIDs:@[play]];
        [MPMusicPlayerController.systemMusicPlayer play];
    }
    partyQueue = [NSMutableArray array];
    tonight = [NSMutableArray array];
    sseClients = [NSMutableArray array];
    startServer();
    [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) { tick(); }];
    [[CADisplayLink displayLinkWithTarget:self selector:@selector(onFrame)] addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    return YES;
}

- (void)onFrame { frame(); }

- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)session
                              options:(UISceneConnectionOptions *)opts {
    UISceneConfiguration *c = [UISceneConfiguration configurationWithName:nil sessionRole:session.role];
    c.delegateClass = [session.role isEqual:UIWindowSceneSessionRoleExternalDisplayNonInteractive] ? TVScene.class : PhoneScene.class;
    return c;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class)); }
}
