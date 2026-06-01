// CNFixEnglish.dll — instant English MEANING names in the WoW 1.12 (5875) UI.
// Layered, all LOCAL (instant at the SetText hook; no async, no IPC):
//   1) g_learned   : meanings harvested from WoWTranslate's Google cache (best),
//                    persisted to CNFix_learned.txt so they're instant forever.
//   2) g_gloss     : 1173 fixed WoW terms (Molten Core, etc).
//   3) smart_compose(): readable component substitution (spaced, ordered) so a
//                       never-seen name is still clean English, never raw Chinese.
// Learning loop: reads WTF/.../WoWTranslate.lua, merges Google names into
// g_learned + appends new ones to CNFix_learned.txt. Ships with a pre-harvested
// CNFix_learned.txt so common names are Google-quality from first launch.
#include <windows.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <unordered_map>
#include <string>
#include <vector>
#include <cctype>
#include <cmath>
#include "MinHook.h"
#include "wnr_common.h"
#include "pinyin_map.h"
#include "meaning_map.h"
#include "glossary_map.h"
#include "namecomp_map.h"

typedef const char* (__fastcall* lua_tostring_t)(void*,int);
typedef void (__fastcall* lua_pushstring_t)(void*,const char*);
typedef void (__fastcall* lua_remove_t)(void*,int);
typedef void (__fastcall* lua_insert_t)(void*,int);
static auto p_lua_tostring=reinterpret_cast<lua_tostring_t>(0x006F3690);
static auto p_lua_pushstring=reinterpret_cast<lua_pushstring_t>(0x006F3890);
static auto p_lua_remove=reinterpret_cast<lua_remove_t>(0x006F30D0);
static auto p_lua_insert=reinterpret_cast<lua_insert_t>(0x006F31A0);

// ===========================================================================
// (perf instrumentation) -- COMPILE-TIME GATED, OFF IN RELEASE
// ---------------------------------------------------------------------------
// The release build does NOT define CNFIX_PERF, so every CNFIX_PERF_* macro
// below expands to nothing: zero counters, zero branches, zero cost on any hot
// path, and nothing written to disk. A developer can build with
// `-DCNFIX_PERF=1` (see build.sh comment) to get lightweight call/hit counters
// dumped to the debug log on a throttled cadence (only when the debug flag file
// is also present). This satisfies "add counters if useful" while guaranteeing
// no noisy debug ships in the release package.
#ifdef CNFIX_PERF
#include <time.h>
static volatile LONG g_pc_overhead=0;   // hk_overhead invocations
static volatile LONG g_pc_overhead_tx=0; // overhead calls that produced a translation
static volatile LONG g_pc_name_hit=0;    // resolve_name cache hits
static volatile LONG g_pc_name_miss=0;   // resolve_name cache misses (ran cascade)
static volatile LONG g_pc_resolve_hit=0; // resolve() (SetText) cache hits
static volatile LONG g_pc_resolve_miss=0;// resolve() cache misses
static volatile LONG g_pc_setlua=0;      // Lua-glue SetText hook fires
static volatile LONG g_pc_setcpp=0;      // C++ leaf SetText fires
static volatile LONG g_pc_guild=0;       // guild getter fires
static DWORD g_pc_lastDump=0;
#define CNFIX_PERF_INC(c) InterlockedIncrement(&(c))
static void cnfix_perf_maybe_dump(){
    DWORD now=GetTickCount();
    if(g_pc_lastDump && now-g_pc_lastDump < 5000) return;   // at most every 5s
    g_pc_lastDump=now;
    wnr_log("PERF/5s: overhead=%ld tx=%ld nameHit=%ld nameMiss=%ld resHit=%ld resMiss=%ld setLua=%ld setCpp=%ld guild=%ld nameCacheEn=%u nameCachePy=%u",
        (long)g_pc_overhead,(long)g_pc_overhead_tx,(long)g_pc_name_hit,(long)g_pc_name_miss,
        (long)g_pc_resolve_hit,(long)g_pc_resolve_miss,(long)g_pc_setlua,(long)g_pc_setcpp,(long)g_pc_guild,
        0u,0u);
    g_pc_overhead=g_pc_overhead_tx=g_pc_name_hit=g_pc_name_miss=0;
    g_pc_resolve_hit=g_pc_resolve_miss=g_pc_setlua=g_pc_setcpp=g_pc_guild=0;
}
#else
#define CNFIX_PERF_INC(c)        ((void)0)
#define cnfix_perf_maybe_dump()  ((void)0)
#endif

static std::unordered_map<uint32_t,const char*> g_py, g_en;
static std::unordered_map<std::string,const char*> g_gloss;
static int g_glossLens[40]; static int g_glossLenCount=0;
static std::unordered_map<std::string,const char*> g_comp;
static int g_compLens[8]; static int g_compLenCount=0;
static std::unordered_map<std::string,std::string> g_learned;
// --- thread safety: the background WTF-scan thread MUST NOT touch the live maps
// directly (unordered_map is not thread-safe; a concurrent insert/rehash while
// the main thread reads = crash). Instead the bg thread parses the file and
// queues pairs here; the MAIN thread drains the queue (calling learn()) at the
// top of hkGlue, so all map access stays single-threaded. ---
static CRITICAL_SECTION g_qcs;
static bool g_qcs_init=false;
static std::vector<std::pair<std::string,std::string>> g_pending;
static void queue_learn(const std::string& zh, const std::string& en){
    if(!g_qcs_init) return;
    EnterCriticalSection(&g_qcs);
    if(g_pending.size() < 5000) g_pending.push_back(std::make_pair(zh,en));
    LeaveCriticalSection(&g_qcs);
}
static bool learn(const std::string&, const std::string&);          // fwd
static void append_learned(const std::string&, const std::string&); // fwd
static void drain_pending(){               // called on MAIN thread only
    if(!g_qcs_init) return;
    std::vector<std::pair<std::string,std::string>> local;
    EnterCriticalSection(&g_qcs);
    if(!g_pending.empty()) local.swap(g_pending);
    LeaveCriticalSection(&g_qcs);
    for(size_t i=0;i<local.size();++i){
        if(learn(local[i].first, local[i].second)) append_learned(local[i].first, local[i].second);
    }
}
static std::unordered_map<std::string,std::string> g_cache;
static std::unordered_map<std::string,std::string> g_reverse;
static char g_learnedPath[300]={0};
static char g_cedictPath[300]={0};
// CC-CEDICT offline contextual dictionary (whole-word zh -> english meaning).
// Used as the base contextual layer AND as longest-match source for compose.
static std::unordered_map<std::string,std::string> g_cedict;
static int g_cedictLens[24]; static int g_cedictLenCount=0;
static std::unordered_map<std::string,std::string> g_chars;   // CC-CEDICT single-char fallback
static char g_charsPath[300]={0};
// WoWTranslate game-term glossary (dungeons/zones/raids) - PROPER NOUNS, highest
// priority after learned, so "哀嚎洞穴" -> "Wailing Caverns" not composed "Wail".
static std::unordered_map<std::string,std::string> g_wtg;
static int g_wtgLens[24]; static int g_wtgLenCount=0;
static char g_wtgPath[300]={0};

static bool has_cjk(const char*s){ for(const unsigned char*p=(const unsigned char*)s;*p;++p) if(*p>=0xE0&&*p<=0xEF) return true; return false; }

// ---- robustness: validate strings before learning/persisting/loading ----
// A truncated multibyte char (e.g. a lead byte with missing continuation bytes)
// makes the p+=3 tokenizer read past the buffer end -> crash. A server-sent name
// clipped at a boundary can do this, get written to CNFix_learned.txt, and then
// crash on every subsequent load. These guards make that impossible.
static const size_t WNR_MAX_LEN = 256;   // names are short; reject absurd lengths

// Returns true only if s is well-formed UTF-8 (every multibyte sequence complete
// and continuation bytes valid). Rejects truncated/!malformed sequences.
static bool valid_utf8(const char* s){
    const unsigned char* p=(const unsigned char*)s;
    while(*p){
        unsigned char c=*p;
        int need;
        if(c<0x80){ p++; continue; }            // ASCII
        else if(c>=0xC2 && c<=0xDF) need=1;     // 2-byte
        else if(c>=0xE0 && c<=0xEF) need=2;     // 3-byte (CJK lives here)
        else if(c>=0xF0 && c<=0xF4) need=3;     // 4-byte
        else return false;                      // invalid lead byte (incl. 0x80-0xBF stray, 0xC0/0xC1, 0xF5+)
        for(int k=1;k<=need;k++){
            unsigned char cc=p[k];
            if(cc<0x80 || cc>0xBF) return false; // missing/!bad continuation -> truncated or malformed
        }
        p+=need+1;
    }
    return true;
}

// Reject strings that would be unsafe to process, learn, or persist:
//  - empty, over-long
//  - containing our delimiter/control bytes (\1 used for the config channel,
//    \2 the passthrough marker) or other control chars that corrupt the file
//  - not well-formed UTF-8 (the crash vector)
static bool safe_str(const std::string& s){
    if(s.empty() || s.size() > WNR_MAX_LEN) return false;
    for(size_t i=0;i<s.size();++i){
        unsigned char c=(unsigned char)s[i];
        if(c=='\t' || c=='\n' || c=='\r') return false;  // field/line breakers
        if(c < 0x20) return false;                      // any control byte (incl \1,\2)
    }
    if(!valid_utf8(s.c_str())) return false;
    return true;
}
// A learnable/persistable pair must be individually safe and shape-correct.
static bool valid_pair(const std::string& zh, const std::string& en){
    if(!safe_str(zh) || !safe_str(en)) return false;
    if(!has_cjk(zh.c_str())) return false;   // zh side must contain CJK
    if(has_cjk(en.c_str()))  return false;   // en side must NOT (it's the translation)
    // ---- (v2.5.11) Loosened name-shape filter --------------------------
    // v2.5.9's filter was too aggressive and killed legitimate contextual
    // player-name translations like "I Will Love You Even To Death"
    // ("You " in the BAD list) or "Why Didn't I Tell You Earlier..."
    // (len>40 + contains "?"). CN players commonly pick sentence-shaped
    // names that translate to long English sentences with pronouns and
    // verbs -- those ARE legitimate names and must pass through.
    //
    // The ZH-side check stays strict (a real player name is pure CJK,
    // 2..12 chars, no punctuation) because that's a tight invariant the
    // server enforces. The EN-side check now rejects only HARD-pattern
    // noise: specific system-message phrases that no player name would
    // contain, terminal punctuation patterns, and length over 80.
    //
    // ZH SIDE: every byte must be CJK (3-byte UTF-8 0xE0..0xEF lead). No
    // ASCII letters/digits/spaces, no fullwidth punctuation, no CJK punct
    // (U+3000..U+303F), no fullwidth ASCII (U+FF00..U+FFEF). 2..12 chars.
    {
        size_t i=0, n=zh.size(); int cjk_chars=0;
        while(i<n){
            unsigned char c0=(unsigned char)zh[i];
            if(c0<0x80) return false;                              // any ASCII = noise
            if(c0<0xE0) return false;                              // 2-byte = noise
            if(c0>0xEF) return false;                              // 4-byte (rare) = noise
            if(i+2>=n) return false;                                // truncated -> noise
            unsigned int cp=((c0&0x0F)<<12) | (((unsigned char)zh[i+1]&0x3F)<<6) | ((unsigned char)zh[i+2]&0x3F);
            if(cp>=0x3000 && cp<=0x303F) return false;             // CJK punct
            if(cp>=0xFF00 && cp<=0xFFEF) return false;             // fullwidth ASCII / punct
            if(cp>=0x2000 && cp<=0x206F) return false;             // general punct
            cjk_chars++;
            i+=3;
        }
        if(cjk_chars<2 || cjk_chars>12) return false;
    }
    // EN SIDE: 80-char hard cap (real names can be long sentences but not
    // paragraphs). Only HIGH-CONFIDENCE noise phrases get rejected --
    // specifically the structural fragments of common system/chat events.
    // Pronouns, verbs, connectives, "the/to/of/and", etc. ALL ALLOWED --
    // they appear naturally in sentence-style player names.
    if(en.size() > 80) return false;
    static const char* BAD[] = {
        // Quest dialogue (system messages, exact phrasing)
        "Accept the quest", "Accept the mission",
        // Party/raid system events
        " leaves the party", " joins the party",
        " leaves the raid",  " joins the raid",
        " leaves the channel", " joins the channel",
        // Combat / death notifications
        " has died.", " was slain by",
        // Item/quest completion notices
        " is complete.", "completes the quest",
        // Interruption / debug markers from cn-server combat addons
        ">>", "<<",
        // Trade-chat patterns
        "Looking For", "looking for",
        // Loot / item received
        " receives loot:", " creates ",
    };
    for(size_t k=0; k<sizeof(BAD)/sizeof(BAD[0]); ++k){
        if(strstr(en.c_str(), BAD[k])){
            // Diagnostic: name-shaped rejections are interesting to see in logs
            // so the user can spot any over-filtering of legitimate contextual
            // translations. Quiet for short en (probably chat noise).
            if(en.size() >= 8 && en.size() <= 60){
                wnr_log("valid_pair: REJECTED en=\"%s\" (matched bad phrase \"%s\")",
                    en.c_str(), BAD[k]);
            }
            return false;
        }
    }
    return true;
}

// Live push channel: the addon sends "\1CNFX\1<zh>\1<english>" via a hidden
// FontString:SetText so WoWTranslate's Google names reach the DLL in REAL TIME
// (in-memory, no /reload). Handled in hkGlue; routes to learn() as an override.
static const char* CTRL = "\1CNFX\1";
// ---- runtime config (pushed from the addon; sensible defaults until then) ----
struct CnfixCfg {
    bool master      = true;   // master on/off
    bool social      = true;   // who / friends / guild
    bool unitframes  = true;   // target / party / player (default frames)
    bool groupfinder = true;   // LFG list + titles
    bool realtime    = true;   // live WoWTranslate learning push
    bool pinyin      = false;  // false = English meaning, true = pinyin sound
    bool overhead    = true;   // floating overhead/3D name translation (GetName path)
    bool tooltipOwnedByOther = true;  // legacy flag (unused since v2.5.2 -- kept for protocol back-compat)
    bool tooltips    = false;  // (v2.5.10+) unified tooltip toggle (name line + body lines)
    bool nameplates  = false;  // (v2.5.7+) experimental: translate Nameplate* frames via SetText pipe
    bool deepHook    = false;  // (v2.5.11) DEFAULT REVERTED TO OFF: leaf hook at 0x00771D80 may
                               //   interfere with the tooltip-harvest pipeline (intercepting before
                               //   WT can read raw zh -> contextual never gets cached). Still
                               //   available as opt-in for users who need it for tooltip/nameplate
                               //   stickiness, but the default is the safer route.
    float nameScale  = 1.0f;  // floating overhead name size multiplier (1.0 = default)
    float nameThresh = 1.0f;  // distance threshold multiplier (1.0 = default 4.0 units)
    float nameDistMul= 1.0f;  // distance growth multiplier (1.0 = default 0.3x)
};
static CnfixCfg g_cfg;
// Globals that wnr_common.h reads via extern (kept volatile so addon flips
// are picked up on the very next SetText without rebuilding any lookup).
// "tooltips" controls both the name line (GameTooltipTextLeft1) and the
// body lines (TextLeft2+, Right*) -- one switch for the whole tooltip
// surface, matching what users actually want.
volatile bool g_surface_tooltipName = false;
volatile bool g_surface_tooltipBody = false;
volatile bool g_surface_nameplates  = false;
// (v2.7.0) VESTIGIAL: the leaf hook now self-restricts to owned surfaces and the
// glue always runs translate_preserving (idempotent second pass), so this is left
// false. Kept only so the glue's historic `&& !g_cpp_hook_active` guard compiles
// and remains a no-op; do not set it true (that would wrongly disable the glue).
static volatile bool g_cpp_hook_active = false;
static const char* CFG = "\1CNFXCFG\1";   // config control: \1CNFXCFG\1<6 chars 0/1>
static const char* CFGSCALE = "\1CNFXSCALE\1";   // scale control: \1CNFXSCALE\1<3 digits> (050..300)
static const char* CFGTHRESH = "\1CNFXTHRS\1";  // threshold control: \1CNFXTHRS\1<3 digits> (020..300)
static const char* CFGDIST  = "\1CNFXDIST\1";   // dist-mult control: \1CNFXDIST\1<3 digits> (020..300)
static bool learn(const std::string& zh, const std::string& en); // fwd
static void invalidate_cache(const std::string& zh);             // fwd
static void fn_apply_scale();                                    // fwd (floating name scaler)
static bool try_push(const char* t){
    // Config control: \1CNFXCFG\1 followed by flag chars (master,social,
    // unitframes,groupfinder,realtime,pinyin,overhead,tooltipOwnedByOther),
    // each '0' or '1'. Trailing flags are optional for back-compat.
    size_t cfglen=strlen(CFG);
    if(strncmp(t,CFG,cfglen)==0){
        const char* f=t+cfglen;
        if(strlen(f)>=6){
            g_cfg.master      = f[0]!='0';
            g_cfg.social      = f[1]!='0';
            g_cfg.unitframes  = f[2]!='0';
            g_cfg.groupfinder = f[3]!='0';
            g_cfg.realtime    = f[4]!='0';
            g_cfg.pinyin      = f[5]!='0';
            g_cfg.overhead    = (strlen(f)>=7) ? (f[6]!='0') : true;  // 7th flag optional
            g_cfg.tooltipOwnedByOther = (strlen(f)>=8) ? (f[7]!='0') : true;  // legacy, unused
            // (v2.7.0) Slot 8 = unified "Tooltips" toggle. Drives the unit-NAME
            // line (GameTooltipTextLeft1) only -- the deep leaf hook translates it
            // and re-asserts on every C++ SetText so WoWTranslate's tooltip rebuild
            // can't revert it to Chinese. BODY lines stay off so WT keeps owning
            // item/quest tooltip text (and its raw-Chinese harvest is never stolen).
            // Slot 9 = nameplates. Slot 10 = legacy deepHook flag: PARSED for wire
            // back-compat but no longer gates anything (the leaf installs by sig).
            g_cfg.tooltips    = (strlen(f)>=9)  ? (f[8]!='0')  : false;
            g_cfg.nameplates  = (strlen(f)>=10) ? (f[9]!='0')  : false;
            g_cfg.deepHook    = (strlen(f)>=11) ? (f[10]!='0') : false;  // legacy/unused
            // Mirror to the volatile globals wnr_common.h reads each SetText call.
            g_surface_tooltipName = g_cfg.tooltips;
            g_surface_tooltipBody = false;                 // WT owns tooltip body
            g_surface_nameplates  = g_cfg.nameplates;
            wnr_log("config: master=%d social=%d uf=%d lfg=%d rt=%d pinyin=%d overhead=%d tipOwn=%d | tooltips=%d plates=%d deepHook=%d",
                g_cfg.master,g_cfg.social,g_cfg.unitframes,g_cfg.groupfinder,
                g_cfg.realtime,g_cfg.pinyin,g_cfg.overhead,g_cfg.tooltipOwnedByOther,
                g_cfg.tooltips,g_cfg.nameplates,g_cfg.deepHook);
        }
        return true;
    }
    // Floating name scale: \1CNFXSCALE\1 followed by 3 digits (050..300 = 0.50x..3.00x).
    // Patches the 0.2f base scale constant inside FUN_006c6e90 at runtime.
    size_t sclen=strlen(CFGSCALE);
    if(strncmp(t,CFGSCALE,sclen)==0){
        const char* d=t+sclen;
        if(strlen(d)>=3){
            int v=0; for(int i=0;i<3;++i){ if(d[i]<'0'||d[i]>'9') break; v=v*10+(d[i]-'0'); }
            if(v>=50 && v<=300){
                float ns=(float)v/100.0f;
                if(fabs(ns - g_cfg.nameScale) > 0.001f){
                    g_cfg.nameScale=ns;
                    fn_apply_scale();
                    wnr_log("nameScale: set to %.2f", g_cfg.nameScale);
                }
            }
        }
        return true;
    }
    // Floating name distance threshold: \1CNFXTHRS\1<3 digits> (020..300 = 0.20x..3.00x).
    size_t thlen=strlen(CFGTHRESH);
    if(strncmp(t,CFGTHRESH,thlen)==0){
        const char* d=t+thlen;
        if(strlen(d)>=3){
            int v=0; for(int i=0;i<3;++i){ if(d[i]<'0'||d[i]>'9') break; v=v*10+(d[i]-'0'); }
            if(v>=20 && v<=300){
                float ns=(float)v/100.0f;
                if(fabs(ns - g_cfg.nameThresh) > 0.001f){
                    g_cfg.nameThresh=ns;
                    fn_apply_scale();
                    wnr_log("nameThresh: set to %.2f", g_cfg.nameThresh);
                }
            }
        }
        return true;
    }
    // Floating name distance multiplier: \1CNFXDIST\1<3 digits> (020..300 = 0.20x..3.00x).
    size_t dllen=strlen(CFGDIST);
    if(strncmp(t,CFGDIST,dllen)==0){
        const char* d=t+dllen;
        if(strlen(d)>=3){
            int v=0; for(int i=0;i<3;++i){ if(d[i]<'0'||d[i]>'9') break; v=v*10+(d[i]-'0'); }
            if(v>=20 && v<=300){
                float ns=(float)v/100.0f;
                if(fabs(ns - g_cfg.nameDistMul) > 0.001f){
                    g_cfg.nameDistMul=ns;
                    fn_apply_scale();
                    wnr_log("nameDistMul: set to %.2f", g_cfg.nameDistMul);
                }
            }
        }
        return true;
    }
    size_t clen=strlen(CTRL);
    if(strncmp(t,CTRL,clen)!=0) return false;
    const char* rest=t+clen; const char* sep=strchr(rest,'\1');
    if(!sep) return true;
    std::string zh(rest,sep-rest), en(sep+1);
    // Respect the realtime toggle: if off, ignore live learning pushes.
    if(g_cfg.realtime && !zh.empty() && !en.empty()){ if(learn(zh,en)) invalidate_cache(zh); }
    return true;
}

static void build(){
    if(!g_qcs_init){ InitializeCriticalSection(&g_qcs); g_qcs_init=true; }  // before bg thread
    for(int i=0;i<kPinyinCount;++i) g_py[kPinyin[i].key]=kPinyin[i].py;
    for(int i=0;i<kMeaningCount;++i) g_en[kMeaning[i].key]=kMeaning[i].en;
    for(int b=0;b<kGlossBucketCount;++b){
        const GlossBucket& gb=kGlossBuckets[b];
        g_glossLens[g_glossLenCount++]=gb.zlen;
        for(int i=0;i<gb.count;++i) g_gloss[std::string(gb.arr[i].zh)]=gb.arr[i].en;
    }
    // name components, track distinct byte-lengths desc for longest-match
    for(int i=0;i<kNameCompCount;++i){
        std::string z(kNameComp[i].zh); g_comp[z]=kNameComp[i].en;
        int L=(int)z.size(); bool seen=false;
        for(int j=0;j<g_compLenCount;++j) if(g_compLens[j]==L) seen=true;
        if(!seen && g_compLenCount<8) g_compLens[g_compLenCount++]=L;
    }
    // sort comp lens desc (simple)
    for(int i=0;i<g_compLenCount;++i) for(int j=i+1;j<g_compLenCount;++j)
        if(g_compLens[j]>g_compLens[i]){ int t=g_compLens[i];g_compLens[i]=g_compLens[j];g_compLens[j]=t; }
}

// ---- smart compose: readable component substitution (Layer 1 baseline) ----
// Append a word with a leading space (except first) and capitalize it.
static void append_word_spaced(std::string& out, const char* w){
    if(!w||!*w) return;
    if(!out.empty()) out += ' ';
    size_t s=out.size();
    for(int i=0; w[i]; ++i){ char c=w[i]; if(c=='/'||c=='\\') break; out+=c; }
    if(out.size()>s) out[s]=(char)toupper((unsigned char)out[s]);
}
// Try longest known phrase (glossary) at p; returns matched byte-len + en.
static int match_gloss(const unsigned char* p, size_t avail, const char** en){
    for(int i=0;i<g_glossLenCount;++i){ int L=g_glossLens[i];
        if((size_t)L>avail) continue;
        auto it=g_gloss.find(std::string((const char*)p,L));
        if(it!=g_gloss.end()){ *en=it->second; return L; } }
    return 0;
}
static int match_comp(const unsigned char* p, size_t avail, const char** en){
    for(int i=0;i<g_compLenCount;++i){ int L=g_compLens[i];
        if((size_t)L>avail) continue;
        auto it=g_comp.find(std::string((const char*)p,L));
        if(it!=g_comp.end()){ *en=it->second; return L; } }
    return 0;
}
static int match_wtg(const unsigned char* p, size_t avail, std::string& en){
    for(int i=0;i<g_wtgLenCount;++i){ int L=g_wtgLens[i];
        if((size_t)L>avail) continue;
        auto it=g_wtg.find(std::string((const char*)p,L));
        if(it!=g_wtg.end()){ en=it->second; return L; } }
    return 0;
}
static int match_cedict(const unsigned char* p, size_t avail, std::string& en){
    for(int i=0;i<g_cedictLenCount;++i){ int L=g_cedictLens[i];
        if((size_t)L>avail) continue;
        auto it=g_cedict.find(std::string((const char*)p,L));
        if(it!=g_cedict.end()){ en=it->second; return L; } }
    return 0;
}
static std::string smart_compose(const char* in){
    std::string out; const unsigned char* p=(const unsigned char*)in;
    size_t total=strlen(in);
    while(*p){
        unsigned char b=*p;
        if(b>=0xE0&&b<=0xEF){
            size_t avail=total-((const char*)p-in);
            const char* en=nullptr; int L=0; std::string ced, wtg;
            if((L=match_wtg(p,avail,wtg))){ append_word_spaced(out,wtg.c_str()); p+=L; continue; }
            if((L=match_cedict(p,avail,ced))){ append_word_spaced(out,ced.c_str()); p+=L; continue; }
            if((L=match_gloss(p,avail,&en))){ append_word_spaced(out,en); p+=L; continue; }
            if((L=match_comp(p,avail,&en))){ append_word_spaced(out,en); p+=L; continue; }
            if(p[1]&&p[2]){
                // single char: curated meaning -> CC-CEDICT char -> pinyin -> raw
                std::string ch((const char*)p,3);
                uint32_t key=(b<<16)|(p[1]<<8)|p[2]; const char* w=nullptr;
                auto m=g_en.find(key); if(m!=g_en.end()) w=m->second;
                if(w){ append_word_spaced(out,w); p+=3; continue; }
                auto cf=g_chars.find(ch);
                if(cf!=g_chars.end()){ append_word_spaced(out,cf->second.c_str()); p+=3; continue; }
                auto y=g_py.find(key); if(y!=g_py.end()){ append_word_spaced(out,y->second); p+=3; continue; }
                out.append((const char*)p,3); p+=3; continue; } }
        else { out+=(char)b; ++p; continue; }
        ++p;
    }
    return out;
}

// ---- the layered resolver: learned -> glossary(exact whole) -> smart_compose ----
// Option A: collapse any multi-word meaning into a SINGLE whitespace-free
// CamelCase token ("Eat Marshmallows" -> "EatMarshmallows"). Essential because a
// name is used as a whitespace-delimited identifier by whisper / /who / invite;
// spaces would split the target and break those features. Single token = native
// behavior, and the reverse-swap key matches exactly what gets sent.
static std::string tokenize(const std::string& s){
    std::string out; bool boundary=true;
    for(size_t i=0;i<s.size();++i){
        unsigned char c=(unsigned char)s[i];
        if(c<0x80){
            if(c==' '||c=='\t'||c==','||c=='.'||c==';'||c==':'||c=='/'||c=='\\'
               ||c=='-'||c=='_'||c=='\''||c=='"'||c=='('||c==')'||c=='['||c==']'
               ||c=='!'||c=='?'||c=='='||c=='+'||c=='&'){ boundary=true; continue; }
            if(boundary && c>='a' && c<='z') c=(unsigned char)(c-'a'+'A');
            out+=(char)c; boundary=false;
        } else { out+=(char)c; boundary=false; }
    }
    return out.empty()? s : out;
}
// Strip WoW color escapes |cAARRGGBB and |r, |H..|h links, and trim spaces, so a
// dungeon/name wrapped in formatting still hits the exact glossary/cedict match.
static std::string strip_fmt(const std::string& in){
    std::string o; size_t i=0, n=in.size();
    while(i<n){
        if(in[i]=='|' && i+1<n){
            char c=in[i+1];
            if(c=='c'){ i+=2; size_t k=0; while(i<n && k<8){ ++i; ++k; } continue; } // |cAARRGGBB
            if(c=='r'){ i+=2; continue; }                                            // |r
            if(c=='H'){ i+=2; while(i<n && in[i]!='|') ++i; continue; }               // |H...
            if(c=='h'){ i+=2; continue; }                                            // |h
        }
        o+=in[i++];
    }
    size_t a=o.find_first_not_of(" \t"); size_t b=o.find_last_not_of(" \t");
    if(a==std::string::npos) return "";
    return o.substr(a,b-a+1);
}
// Romanize every CJK char to its toneless pinyin syllable, CamelCase-joined.
// No meaning, no glossary - this is the pinyin MODE path. ASCII passes through.
static std::unordered_map<std::string,std::string> g_pyCache;   // zh -> pinyin token
static std::unordered_map<std::string,std::string> g_pyReverse; // pinyin token -> zh
// (perf) Memoization for resolve_name() -- the overhead/guild getter resolver,
// which runs on EVERY plate recompose for EVERY visible Chinese name. It was
// previously uncached, so a crowd of not-yet-learned names recomposed the full
// dictionary/compose/pinyin cascade every frame. These two maps (mode-separated,
// mirroring the g_cache/g_pyCache split used by resolve()) memoize the result.
// A value of "" is a NEGATIVE cache entry (input couldn't be de-Sinified) so we
// don't retry the cascade every frame. Both are cleared for a zh when a contextual
// is learned (invalidate_cache), so a freshly-learned name still upgrades promptly.
static std::unordered_map<std::string,std::string> g_nameCacheEn; // overhead resolve, English mode
static std::unordered_map<std::string,std::string> g_nameCachePy; // overhead resolve, pinyin mode
static std::string romanize_pinyin(const std::string& zh){
    std::string out; size_t i=0,n=zh.size();
    while(i<n){
        unsigned char c=(unsigned char)zh[i];
        if(c>=0xE0 && c<=0xEF && i+2<n){
            uint32_t key=((uint32_t)(unsigned char)zh[i]<<16)|((uint32_t)(unsigned char)zh[i+1]<<8)|(unsigned char)zh[i+2];
            auto it=g_py.find(key);
            if(it!=g_py.end()){
                const char* py=it->second;
                if(py && py[0]){ out+=(char)toupper((unsigned char)py[0]); out+=py+1; }
            }
            i+=3; continue;
        }
        // keep ASCII letters/digits verbatim (codes, numbers); skip stray spaces
        if(c!=' ') out+=zh[i];
        i++;
    }
    return out;
}
static std::string compose_name(const char* in);   // fwd: glossary-free name composer (defined below, shared with resolve_name)
static const std::string& resolve(const std::string& zh){
    if(g_cfg.pinyin){
        auto pc=g_pyCache.find(zh);
        if(pc!=g_pyCache.end()) return pc->second;
        std::string py=romanize_pinyin(strip_fmt(zh).empty()?zh:strip_fmt(zh));
        if(py.empty()) py=zh;
        auto pit=g_pyCache.emplace(zh,py).first;
        g_pyReverse[py]=zh;
        return pit->second;
    }
    auto c=g_cache.find(zh);
    if(c!=g_cache.end()){ CNFIX_PERF_INC(g_pc_resolve_hit); return c->second; }
    CNFIX_PERF_INC(g_pc_resolve_miss);
    std::string en; const char* layer="?";
    std::string key=strip_fmt(zh); if(key.empty()) key=zh;
    // GLOSSARY (game terms / dungeons) ALWAYS wins - checked before learned and
    // cedict so it can never be overridden by a stale learned entry or CC-CEDICT.
    auto wg=g_wtg.find(key);
    if(wg!=g_wtg.end()){ en=wg->second; layer="wtgloss"; }
    else {
        auto L=g_learned.find(key);
        if(L!=g_learned.end()){ en=L->second; layer="learned"; }
        else {
            auto ce=g_cedict.find(key);
            if(ce!=g_cedict.end()){ en=ce->second; layer="cedict"; }
            else {
                auto g=g_gloss.find(key);
                if(g!=g_gloss.end()){ en=g->second; layer="gloss"; }
                // UNIFIED FALLBACK: use the glossary-free compose_name() (the same
                // composer resolve_name() uses for overhead/guild) instead of
                // smart_compose(), so a name that misses learned/cedict resolves to
                // the SAME words on the unit frame as it does over the head, and
                // game-term slang (pet/DPS/HP/LFG/Sap...) can never hijack a name on
                // the SetText surface. Glossary still wins FIRST above (g_wtg) for real
                // game terms/dungeons, and tokenize() below still applies for
                // whisper/who/invite identifier safety -- so this is purely the
                // last-resort composer, now consistent across every surface.
                else { en=compose_name(key.c_str()); layer="compose"; }
            }
        }
    }
    en=tokenize(en);                                     // single-token (Option A)
    (void)layer;
    auto it=g_cache.emplace(zh,en).first;
    g_reverse[en]=zh;
    return it->second;
}

// ---- learning loop: harvest WoWTranslate's Google cache + persist ----
static std::string gamedir(){
    char buf[600]={0}; GetModuleFileNameA(GetModuleHandleA(NULL),buf,sizeof(buf)-1);
    std::string p(buf); size_t s=p.find_last_of("\\/");
    return s==std::string::npos? std::string(".") : p.substr(0,s);
}
static std::string read_file(const std::string& path){
    FILE* f=fopen(path.c_str(),"rb"); if(!f) return "";
    fseek(f,0,SEEK_END); long n=ftell(f); fseek(f,0,SEEK_SET);
    if(n<=0||n>40*1024*1024){ fclose(f); return ""; }
    std::string s; s.resize(n); size_t rd=fread(&s[0],1,n,f); fclose(f); s.resize(rd); return s;
}
// add zh->en to learned (memory + cache override) and return true if NEW.
static std::string tokenize(const std::string& s); // fwd
static bool learn(const std::string& zh, const std::string& en){
    if(!valid_pair(zh,en)) return false;   // reject malformed/!unsafe (crash guard)
    // Glossary terms (dungeons/zones/raids) keep DISPLAY supremacy in resolve()
    // (which checks g_wtg first). But we MUST still persist the contextual Google
    // translation to learned so the data exists for name surfaces that bypass the
    // glossary (CNFixGetNameLab / SnapUI). So: always persist; just don't let a
    // glossary-colliding pair override the game term in the live display cache.
    bool glossOwned = (g_wtg.find(zh)!=g_wtg.end());
    auto it=g_learned.find(zh);
    if(it!=g_learned.end() && it->second==en) return false;   // already have it
    g_learned[zh]=en;                          // ALWAYS persist (file + name coverage)
    if(!glossOwned){
        std::string tok=tokenize(en);
        g_cache[zh]=tok; g_reverse[tok]=zh;    // display override only when NOT a game term
    }
    return true;                               // -> append_learned writes it to disk
}
static void invalidate_cache(const std::string& zh){
    // force next resolve() to recompute (override now in g_learned)
    g_cache.erase(zh);
    // (perf) The overhead resolve_name caches are keyed by the FULL engine string
    // (which may carry a leading PvP rank), not the bare zh, so an exact-key erase
    // can't target them. invalidate_cache only fires when learn() actually changed
    // something (new contextual) -- which is infrequent and deduplicated -- so we
    // clear both name caches wholesale. The cost is at most one re-resolve per
    // visible plate on the next frame, which is precisely the word-sub -> contextual
    // upgrade we want; it does not recur because the new resolve is re-cached.
    if(!g_nameCacheEn.empty()) g_nameCacheEn.clear();
    if(!g_nameCachePy.empty()) g_nameCachePy.clear();
}
// parse WoWTranslate.lua entries ["...wt_name:ZH"]="EN"
static int harvest_wt(const std::string& data){
    int added=0; size_t pos=0; const std::string KEY="wt_name:";
    while((pos=data.find(KEY,pos))!=std::string::npos){
        size_t ks=pos+KEY.size(); size_t q=data.find('"',ks);
        if(q==std::string::npos){ pos=ks; continue; }
        std::string zh=data.substr(ks,q-ks);
        size_t eq=data.find('=',q); if(eq==std::string::npos){ pos=q+1; continue; }
        size_t vq=data.find('"',eq); if(vq==std::string::npos){ pos=q+1; continue; }
        size_t vq2=data.find('"',vq+1); if(vq2==std::string::npos){ pos=q+1; continue; }
        std::string en=data.substr(vq+1,vq2-(vq+1)); pos=vq2+1;
        if(learn(zh,en)) added++;
    }
    return added;
}
// load our persisted learned file: "<zh>\t<en>" per line
static void load_learned_file(){
    std::string data=read_file(g_learnedPath); if(data.empty()) return;
    size_t i=0,n=data.size();
    bool dropped=false;                       // did we skip any bad entries?
    std::string clean;                        // rebuilt file with only safe pairs
    while(i<n){ size_t e=data.find('\n',i); if(e==std::string::npos) e=n;
        std::string line=data.substr(i,e-i); i=e+1;
        if(!line.empty()&&line[line.size()-1]=='\r') line.erase(line.size()-1);
        if(line.empty()) continue;
        size_t tab=line.find('\t'); if(tab==std::string::npos){ dropped=true; continue; }
        std::string zh=line.substr(0,tab), en=line.substr(tab+1);
        if(!valid_pair(zh,en)){ dropped=true; continue; }   // skip poison, don't crash
        learn(zh,en);
        clean.append(zh); clean.push_back('\t'); clean.append(en); clean.push_back('\n');
    }
    // Self-heal: if the file contained bad/!malformed entries, rewrite it clean so
    // the crash can never recur on future launches.
    if(dropped){
        FILE* f=fopen(g_learnedPath,"wb");
        if(f){ if(!clean.empty()) fwrite(clean.data(),1,clean.size(),f); fclose(f);
               wnr_log("learned-file: removed malformed entries, rewrote clean"); }
    }
}
// append newly-learned pairs to our file (so they persist for next launch)
static void load_cedict_file(){
    std::string data=read_file(g_cedictPath); if(data.empty()) return;
    size_t i=0,n=data.size();
    while(i<n){ size_t e=data.find('\n',i); if(e==std::string::npos) e=n;
        std::string line=data.substr(i,e-i); i=e+1;
        if(!line.empty()&&line[line.size()-1]=='\r') line.erase(line.size()-1);
        size_t tab=line.find('\t'); if(tab==std::string::npos) continue;
        std::string zh=line.substr(0,tab), en=line.substr(tab+1);
        if(zh.empty()||en.empty()||!has_cjk(zh.c_str())) continue;
        if(g_cedict.find(zh)==g_cedict.end()){
            g_cedict[zh]=en;
            int L=(int)zh.size(); bool seen=false;
            for(int j=0;j<g_cedictLenCount;++j) if(g_cedictLens[j]==L) seen=true;
            if(!seen && g_cedictLenCount<24) g_cedictLens[g_cedictLenCount++]=L;
        }
    }
    // sort lengths desc for longest-match
    for(int a=0;a<g_cedictLenCount;++a) for(int b=a+1;b<g_cedictLenCount;++b)
        if(g_cedictLens[b]>g_cedictLens[a]){ int t=g_cedictLens[a];g_cedictLens[a]=g_cedictLens[b];g_cedictLens[b]=t; }
}
static void load_wtg_file(){
    std::string data=read_file(g_wtgPath); if(data.empty()) return;
    size_t i=0,n=data.size();
    while(i<n){ size_t e=data.find('\n',i); if(e==std::string::npos) e=n;
        std::string line=data.substr(i,e-i); i=e+1;
        if(!line.empty()&&line[line.size()-1]=='\r') line.erase(line.size()-1);
        size_t tab=line.find('\t'); if(tab==std::string::npos) continue;
        std::string zh=line.substr(0,tab), en=line.substr(tab+1);
        if(zh.empty()||en.empty()||!has_cjk(zh.c_str())) continue;
        if(g_wtg.find(zh)==g_wtg.end()){
            g_wtg[zh]=en; int L=(int)zh.size(); bool seen=false;
            for(int j=0;j<g_wtgLenCount;++j) if(g_wtgLens[j]==L) seen=true;
            if(!seen && g_wtgLenCount<24) g_wtgLens[g_wtgLenCount++]=L;
        }
    }
    for(int a=0;a<g_wtgLenCount;++a) for(int b=a+1;b<g_wtgLenCount;++b)
        if(g_wtgLens[b]>g_wtgLens[a]){ int t=g_wtgLens[a];g_wtgLens[a]=g_wtgLens[b];g_wtgLens[b]=t; }
}
// Load ONE combined dictionary file (CNFix_data.txt) with ##SECTION: markers.
// Tidier install (single file). Returns true if the combined file was found.
static bool load_combined_file(){
    std::string path=gamedir()+"\\CNFix_data.txt";
    std::string data=read_file(path.c_str()); if(data.empty()) return false;
    int section=0; // 0 none,1 glossary,2 cedict,3 chars,4 learned
    size_t i=0,n=data.size();
    while(i<n){ size_t e=data.find('\n',i); if(e==std::string::npos) e=n;
        std::string line=data.substr(i,e-i); i=e+1;
        if(!line.empty()&&line[line.size()-1]=='\r') line.erase(line.size()-1);
        if(line.size()>=10 && line.compare(0,10,"##SECTION:")==0){
            std::string sec=line.substr(10);
            if(sec=="GLOSSARY") section=1; else if(sec=="CEDICT") section=2;
            else if(sec=="CHARS") section=3; else if(sec=="LEARNED") section=4;
            else section=0;
            continue;
        }
        if(line.empty()||line[0]=='#') continue;
        size_t tab=line.find('\t'); if(tab==std::string::npos) continue;
        std::string zh=line.substr(0,tab), en=line.substr(tab+1);
        if(zh.empty()||en.empty()||!has_cjk(zh.c_str())) continue;
        if(section==1){ if(g_wtg.find(zh)==g_wtg.end()){ g_wtg[zh]=en;
            int L=(int)zh.size(); bool sn=false; for(int j=0;j<g_wtgLenCount;++j) if(g_wtgLens[j]==L) sn=true;
            if(!sn&&g_wtgLenCount<24) g_wtgLens[g_wtgLenCount++]=L; } }
        else if(section==2){ if(g_cedict.find(zh)==g_cedict.end()){ g_cedict[zh]=en;
            int L=(int)zh.size(); bool sn=false; for(int j=0;j<g_cedictLenCount;++j) if(g_cedictLens[j]==L) sn=true;
            if(!sn&&g_cedictLenCount<24) g_cedictLens[g_cedictLenCount++]=L; } }
        else if(section==3){ g_chars[zh]=en; }
        else if(section==4){ g_learned[zh]=en; std::string tk=tokenize(en); g_cache[zh]=tk; g_reverse[tk]=zh; }
    }
    // sort length buckets desc
    for(int a=0;a<g_wtgLenCount;++a) for(int b=a+1;b<g_wtgLenCount;++b)
        if(g_wtgLens[b]>g_wtgLens[a]){int t=g_wtgLens[a];g_wtgLens[a]=g_wtgLens[b];g_wtgLens[b]=t;}
    for(int a=0;a<g_cedictLenCount;++a) for(int b=a+1;b<g_cedictLenCount;++b)
        if(g_cedictLens[b]>g_cedictLens[a]){int t=g_cedictLens[a];g_cedictLens[a]=g_cedictLens[b];g_cedictLens[b]=t;}
    return true;
}
static void load_chars_file(){
    std::string data=read_file(g_charsPath); if(data.empty()) return;
    size_t i=0,n=data.size();
    while(i<n){ size_t e=data.find('\n',i); if(e==std::string::npos) e=n;
        std::string line=data.substr(i,e-i); i=e+1;
        if(!line.empty()&&line[line.size()-1]=='\r') line.erase(line.size()-1);
        size_t tab=line.find('\t'); if(tab==std::string::npos) continue;
        std::string zh=line.substr(0,tab), en=line.substr(tab+1);
        if(!zh.empty()&&!en.empty()&&has_cjk(zh.c_str())) g_chars[zh]=en;
    }
}
static void append_learned(const std::string& zh, const std::string& en){
    if(!valid_pair(zh,en)) return;         // never persist unsafe pairs
    FILE* f=fopen(g_learnedPath,"ab"); if(!f) return;
    fprintf(f,"%s\t%s\n",zh.c_str(),en.c_str()); fclose(f);
}
static void scan_wtf_and_learn(){
    std::string base=gamedir()+"\\WTF\\Account";
    std::string glob=base+"\\*"; WIN32_FIND_DATAA fd;
    HANDLE h=FindFirstFileA(glob.c_str(),&fd); if(h==INVALID_HANDLE_VALUE) return;
    do{
        if(!(fd.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY)) continue;
        if(fd.cFileName[0]=='.') continue;
        std::string sv=base+"\\"+std::string(fd.cFileName)+"\\SavedVariables\\WoWTranslate.lua";
        std::string data=read_file(sv); if(data.empty()) continue;
        // Harvest BOTH cache key forms WoWTranslate uses:
        //   1) ["\1wt_name:<zh>"] = "<en>"   (the name-translation path)
        //   2) ["<zh>"]            = "<en>"   (raw-text path: chat/tooltip/LFG)
        // Form 2 is where idiomatic tooltip translations (e.g. Supernova) live,
        // so we MUST read it for those to override our literal composition.
        // Generic line scan: find each ["KEY"] = "VALUE" pair.
        size_t pos=0, n2=data.size();
        while(pos<n2){
            size_t k1=data.find('"',pos); if(k1==std::string::npos) break;
            // skip if this quote is a value (we always pair key->value in order)
            size_t k2=data.find('"',k1+1); if(k2==std::string::npos) break;
            std::string key=data.substr(k1+1,k2-(k1+1));
            // find '=' then the value quotes
            size_t eq=data.find('=',k2);
            size_t nl=data.find('\n',k2);
            if(eq==std::string::npos || (nl!=std::string::npos && eq>nl)){ pos=k2+1; continue; }
            size_t v1=data.find('"',eq); if(v1==std::string::npos){ pos=k2+1; continue; }
            size_t v2=data.find('"',v1+1); if(v2==std::string::npos){ pos=k2+1; continue; }
            std::string val=data.substr(v1+1,v2-(v1+1));
            pos=v2+1;
            // strip a leading name prefix if present
            std::string zh=key;
            const std::string NK="wt_name:";
            size_t np=zh.find(NK);
            if(np!=std::string::npos) zh=zh.substr(np+NK.size());
            // also skip the "guild:" sub-namespace marker
            if(zh.compare(0,6,"guild:")==0) zh=zh.substr(6);
            // accept names + short titles (<=45 bytes ~ up to ~15 CJK chars),
            // skip long chat sentences. require CJK key, ASCII value.
            if(!zh.empty() && zh.size()<=45 && has_cjk(zh.c_str()) && !val.empty() && !has_cjk(val.c_str())){
                queue_learn(zh,val);   // bg thread: queue only, main thread applies
            }
        }
    } while(FindNextFileA(h,&fd));
    FindClose(h);
}

// ---- display hook: swap CJK name -> resolved meaning (instant, layered) ----
typedef int(__fastcall* glue_t)(void*);
static glue_t oGlue=nullptr;
// Translate a display string while PRESERVING formatting: leading |cAARRGGBB color
// (and |H link) codes, a trailing |r, and a trailing " - Offline"/" - Online"
// status suffix are kept; only the inner name is translated. Fixes color changes
// on the friends list (offline grey) and avoids "NameOffline" mashing.
// GLOSSARY-ONLY substitution for the LFG window: replace ONLY known game terms
// (g_wtg) via longest-match; leave ALL other text verbatim - digits, codes like
// "4=1" / "T N M D", punctuation, and untranslated Chinese.
static bool glossary_only(const char* t, std::string& outStr){
    if(!t || !valid_utf8(t) || strlen(t) > WNR_MAX_LEN*4) return false;  // crash guard
    std::string in(t); size_t n=in.size(); std::string out; bool changed=false;
    size_t i=0;
    while(i<n){
        unsigned char c=(unsigned char)in[i];
        if(c>=0xE0 && c<=0xEF){
            size_t avail=n-i; int hitLen=0; const std::string* hitEn=nullptr;
            for(int k=0;k<g_wtgLenCount;++k){ int Lb=g_wtgLens[k];
                if((size_t)Lb>avail) continue;
                auto it=g_wtg.find(in.substr(i,Lb));
                if(it!=g_wtg.end()){ hitLen=Lb; hitEn=&it->second; break; } }
            if(hitEn){
                if(!out.empty() && out[out.size()-1]!=' ') out+=' ';
                out+=*hitEn; out+=' '; i+=hitLen; changed=true; continue;
            }
            out.append(in,i,3); i+=3; continue;
        }
        out+=in[i++];
    }
    std::string tidy; for(size_t j=0;j<out.size();++j){
        if(out[j]==' ' && !tidy.empty() && tidy[tidy.size()-1]==' ') continue;
        tidy+=out[j]; }
    while(!tidy.empty() && tidy[tidy.size()-1]==' ') tidy.erase(tidy.size()-1);
    if(!changed) return false;
    outStr=tidy; return true;
}
static bool translate_preserving(const char* t, std::string& outStr){
    if(!t) return false;
    // CRASH GUARD: never process malformed/!truncated UTF-8 (a server-sent name
    // clipped mid-character could otherwise walk past the buffer). Also cap
    // absurd lengths. If it's not clean, leave the text untranslated.
    if(strlen(t) > WNR_MAX_LEN*4) return false;
    if(!valid_utf8(t)) return false;
    std::string in(t); size_t m=in.size();
    if(!has_cjk(in.c_str())) return false;              // no CJK -> nothing to do
    // (v2.6.0) MULTI-RUN: byte-walk the whole string and resolve() EVERY CJK run,
    // copying all ASCII (spaces, '<', '>', "'s Pet>", level numbers, brackets) and
    // every WoW escape code through verbatim. This fixes pet/companion strings such
    // as "迅猛龙 <东邪's Pet>" where the OWNER name lived in a *second* CJK run after
    // the first space and so was never translated by the old prefix/core/suffix
    // single-run splitter. resolve() per run keeps the unit-frame/nameplate cascade
    // (g_wtg->g_learned->g_cedict->g_gloss->compose) and CamelCase tokenizing, so a
    // pet's display name AND its owner come out as the SAME words seen everywhere.
    std::string out, run; bool changed=false;
    auto flush=[&](){
        if(run.empty()) return;
        const std::string& en=resolve(run);
        if(!en.empty() && en!=run && !has_cjk(en.c_str()) && valid_utf8(en.c_str())){
            out+=en; changed=true;
        } else {
            out+=run;                                   // never write back garbage/raw ZH
        }
        run.clear();
    };
    const unsigned char* p=(const unsigned char*)in.c_str();
    for(size_t i=0;i<m;){
        unsigned char c=p[i];
        // WoW escape codes pass through verbatim so their payload bytes are never
        // mistaken for translatable text and hyperlinks are never corrupted.
        if(c=='|' && i+1<m){
            char d=(char)p[i+1];
            if(d=='c'){ flush(); out+="|c"; i+=2; size_t k=0; while(i<m&&k<8){ out+=(char)p[i++]; ++k; } continue; }
            if(d=='r'){ flush(); out+="|r"; i+=2; continue; }
            // |Hplayer:<zh>|h : keep the link PAYLOAD (the click-to-target key) as
            // the real Chinese name, exactly like the action reverse-swap relies on;
            // only the [display] segment after |h is translated by the normal walk.
            if(d=='H'){ flush(); out+="|H"; i+=2; while(i<m&&p[i]!='|'){ out+=(char)p[i++]; } continue; }
            if(d=='h'){ flush(); out+="|h"; i+=2; continue; }
        }
        if(c>=0xE0 && c<=0xEF && i+2<m && p[i+1] && p[i+2]){ // 3-byte CJK char
            run.append((const char*)p+i,3); i+=3; continue;
        }
        flush(); out+=(char)c; ++i;
    }
    flush();
    if(!changed) return false;                          // resolved nothing -> leave as-is
    if(out.size() >= WNR_MAX_LEN*4 || !valid_utf8(out.c_str())) return false;
    outStr=out; return true;
}
static int __fastcall hkGlue(void* L){
    drain_pending();   // apply any bg-queued learned pairs on THIS (main) thread
    if(!IsBadCodePtr((FARPROC)p_lua_tostring)){
        const char* t=p_lua_tostring(L,2);
        if(t && !IsBadReadPtr(t,1)){
            // live push from addon? store override + suppress (show empty).
            if(t[0]=='\1' && try_push(t)){
                p_lua_pushstring(L,""); p_lua_remove(L,2);
                return oGlue(L);
            }
            // PASSTHROUGH marker (\2): the addon is setting text it wants left
            // EXACTLY as-is (e.g. restoring the real Chinese name on a surface
            // whose toggle is off). Strip the marker, set the raw text, and do
            // NOT translate. This lets the addon "unhook" specific frames so the
            // DLL can't re-translate the addon's own restore call.
            if(t[0]=='\2'){
                p_lua_pushstring(L, t+1); p_lua_remove(L,2);
                return oGlue(L);
            }
            if(has_cjk(t) && g_cfg.master){
                CNFIX_PERF_INC(g_pc_setlua);
                // LFG list: glossary-only, gated by the Group Finder toggle.
                // (LFG frames ARE named, so we can detect them here.)
                // Social / UnitFrames toggles are enforced addon-side, because
                // those row FontStrings return no name at the C level (verified
                // via debug log) so the DLL can't distinguish them.
                const char* lfg=wnr_lfg_frame_name(L);
                if(lfg){
                    if(g_cfg.groupfinder){
                        std::string outStr;
                        if(glossary_only(t,outStr)){
                            p_lua_pushstring(L,outStr.c_str());
                            p_lua_remove(L,2);
                        }
                    }
                } else if(!g_cpp_hook_active && !wnr_target_should_skip(L)){
                    // (v2.5.8+) When the C++ leaf hook is active it handles
                    // translation; the Lua glue hook only consumes control
                    // strings to avoid double-translating. Idempotent
                    // anyway (a translated string has no CJK so the second
                    // pass is a no-op), but skipping saves the work.
                    std::string outStr;
                    if(translate_preserving(t,outStr)){
                        p_lua_pushstring(L,outStr.c_str());
                        p_lua_remove(L,2);
                    }
                }
            }
        }
    }
    return oGlue(L);
}
// ---- action reverse-swap: meaning -> real ZH before it hits the server ----
static void swap_back(void* L,int idx){
    if(IsBadCodePtr((FARPROC)p_lua_tostring)) return;
    const char* name=p_lua_tostring(L,idx);
    if(!name||IsBadReadPtr(name,1)) return;
    std::string key(name);
    auto& rev = g_cfg.pinyin ? g_pyReverse : g_reverse;   // mode-aware reverse map
    auto it=rev.find(key);
    if(it==rev.end()){
        // Recipient fields capitalize the first letter; try a case-normalized match.
        std::string lk=key; for(char&c:lk) c=(char)tolower((unsigned char)c);
        const std::string* zh=nullptr;
        for(auto& kv : rev){
            std::string a=kv.first; for(char&c:a) c=(char)tolower((unsigned char)c);
            if(a==lk){ zh=&kv.second; break; }
        }
        if(zh){
            p_lua_pushstring(L,zh->c_str()); p_lua_insert(L,idx); p_lua_remove(L,idx+1);
            return;
        }
        return;
    }
    p_lua_pushstring(L,it->second.c_str());
    p_lua_insert(L,idx);
    p_lua_remove(L,idx+1);
}
typedef int(__fastcall* act_t)(void*);
#define MKACT1(NAME,ADDR) static act_t o_##NAME=nullptr; \
  static int __fastcall hk_##NAME(void* L){ swap_back(L,1); return o_##NAME(L); }
MKACT1(InviteByName,0x0048A420) MKACT1(GuildInviteByName,0x0048AEF0)
MKACT1(InviteToParty,0x0048A3B0) MKACT1(AddFriend,0x005AD290)
MKACT1(InitiateTrade,0x0048A120) MKACT1(TargetByName,0x00489D60)
MKACT1(SendMail,0x004AE800)
static act_t o_SendChatMessage=nullptr;
static int __fastcall hk_SendChatMessage(void* L){ swap_back(L,4); return o_SendChatMessage(L); }

// ================= OVERHEAD / 3D FLOATING NAME TRANSLATION =================
// Hooks the name formatter FUN_00609370 (the GetName overhead path), which the
// global SetText hook never sees. Uses a NAME-ONLY resolver that consults only
// g_learned + g_cedict (+ per-char g_chars/g_py) and NEVER g_wtg/g_gloss or
// smart_compose -- so game-term glossary slang can't hijack a player name, and
// the word-sub glossary/validation error never applies to overhead names.
static std::string gn_trim(const std::string& s){
    size_t a=0,b=s.size(); while(a<b&&(unsigned char)s[a]<=' ')a++; while(b>a&&(unsigned char)s[b-1]<=' ')b--; return s.substr(a,b-a);
}
static bool name_whole(const std::string& k, std::string& out){
    auto l=g_learned.find(k); if(l!=g_learned.end()){ out=l->second; return true; }
    auto c=g_cedict.find(k);  if(c!=g_cedict.end()){  out=c->second; return true; }
    return false;
}
// Glossary-free composer for a single CJK run. Identical in spirit to
// smart_compose() BUT deliberately omits match_wtg()/match_gloss() so game-term
// slang (pet/DPS/HP/LFG/Sap...) can never hijack a player name. Order per token:
//   cedict longest-match -> curated single-char meaning (g_en) -> CC-CEDICT
//   single char (g_chars) -> pinyin (g_py) -> raw (last resort).
// This is the safety net that makes overhead names ALWAYS resolve to readable
// English instead of falling back to raw Chinese (the 30/70 problem).
static std::string compose_name(const char* in){
    std::string out; const unsigned char* p=(const unsigned char*)in;
    size_t total=strlen(in);
    while(*p){
        unsigned char b=*p;
        if(b>=0xE0&&b<=0xEF && p[1] && p[2]){
            size_t avail=total-((const char*)p-in);
            std::string ced; int L;
            if((L=match_cedict(p,avail,ced))){ append_word_spaced(out,ced.c_str()); p+=L; continue; }
            std::string ch((const char*)p,3);
            uint32_t key=(b<<16)|(p[1]<<8)|p[2]; const char* w=nullptr;
            auto m=g_en.find(key); if(m!=g_en.end()) w=m->second;
            if(w){ append_word_spaced(out,w); p+=3; continue; }
            auto cf=g_chars.find(ch);
            if(cf!=g_chars.end()){ append_word_spaced(out,cf->second.c_str()); p+=3; continue; }
            auto y=g_py.find(key); if(y!=g_py.end()){ append_word_spaced(out,y->second); p+=3; continue; }
            out.append((const char*)p,3); p+=3; continue;
        }
        out+=(char)b; ++p;
    }
    return out;
}
// Translate a CJK overhead name. Returns true (with result set) only if changed.
// ===================== EXPERIMENT (revertible) =====================
// Render the de-Sinified overhead NAME in CamelCase (a single whitespace-free
// token, matching the who/nameplate/social/inspect SetText path which runs
// tokenize()), while keeping any leading ASCII rank/title prefix SEPARATE with a
// single space (never smush rank+name). rankBytes = count of leading ASCII in
// the SOURCE name (the PvP rank/title), which is copied verbatim into the result.
// TO REVERT: delete this function and the two camel_overhead_name(...) calls in
// resolve_name() below (restore `result=whole;` and `result=r;`).
static std::string camel_overhead_name(const std::string& s, size_t rankBytes){
    if(rankBytes>s.size()) rankBytes=s.size();
    std::string pre=s.substr(0,rankBytes);     // rank/title (verbatim leading ASCII)
    std::string name=s.substr(rankBytes);      // de-Sinified name part
    size_t e=pre.find_last_not_of(' ');
    if(e!=std::string::npos) pre=pre.substr(0,e+1); else pre.clear();
    size_t a=name.find_first_not_of(' ');
    if(a!=std::string::npos) name=name.substr(a); else name.clear();
    std::string tok=tokenize(name);            // CamelCase, whitespace-free
    if(tok.empty()) return s;
    return pre.empty()? tok : (pre+" "+tok);
}
// =================== END EXPERIMENT helper ===================
static bool resolve_name_uncached(const char* in, std::string& result){
    if(!has_cjk(in) || !valid_utf8(in)) return false;
    if(g_cfg.pinyin){                                   // pinyin mode mirrors the panel radio
        // Preserve a leading ASCII rank/title ("Scout ", "Sergeant ") and only
        // romanize the CJK part, so the rank stays SEPARATED from the pinyin name
        // ("Scout WeiLiang", not "ScoutWeiLiang"). romanize_pinyin() drops spaces
        // to join multi-syllable names, which is why feeding it the whole string
        // jammed the rank onto the name.
        size_t ap=0; while(in[ap] && (unsigned char)in[ap]<0x80) ap++;  // leading ASCII
        std::string pre(in,ap);
        std::string py=romanize_pinyin(in+ap);          // romanize CJK remainder only
        if(!py.empty() && !has_cjk(py.c_str())){
            size_t e=pre.find_last_not_of(' ');
            if(e!=std::string::npos) pre=pre.substr(0,e+1); else pre.clear();
            std::string out = pre.empty() ? py : (pre + " " + py);
            if(out!=in){ result=out; return true; }
        }
        return false;
    }
    size_t pfx=0; while(in[pfx] && (unsigned char)in[pfx]<0x80) pfx++;  // leading ASCII (PvP rank)
    std::string whole;
    if(name_whole(in,whole) && !whole.empty() && !has_cjk(whole.c_str()) && valid_utf8(whole.c_str())){
        std::string tp(in,pfx);                         // poison guard: reject "Sergeant 恶鬼踏江"->"Sergeant"
        if(gn_trim(tp).empty() || gn_trim(whole)!=gn_trim(tp)){ if(whole!=in){ result=camel_overhead_name(whole,pfx); return true; } }   // EXPERIMENT: was result=whole;
    }
    std::string r, run;
    auto flush=[&](){ if(run.empty())return; std::string en;
        if(name_whole(run,en)&&!en.empty()&&!has_cjk(en.c_str())&&valid_utf8(en.c_str())) r+=en;
        else { std::string c=compose_name(run.c_str());     // glossary-free safety net
               if(!c.empty()&&!has_cjk(c.c_str())) r+=c;
               else { std::string py=romanize_pinyin(run);  // last resort: pure-ASCII pinyin
                      if(!py.empty()&&!has_cjk(py.c_str())) r+=py; else r+=run; } }
        run.clear(); };
    const unsigned char* p=(const unsigned char*)in;
    while(*p){ if(*p>=0xE0&&*p<=0xEF&&p[1]&&p[2]){ run.append((const char*)p,3); p+=3; } else { flush(); r.push_back((char)*p); ++p; } }
    flush();
    if(r.empty()||r==in||has_cjk(r.c_str())) return false;   // only claim success if fully de-Sinified
    result=camel_overhead_name(r,pfx); return true;          // EXPERIMENT: was result=r;
}
// (perf) Memoizing front for resolve_name(). Looks up the per-mode cache first;
// on miss runs the (expensive) uncached cascade ONCE and stores the result --
// including a negative ("") entry so an un-translatable name isn't re-attempted
// every frame. Cache key is the raw engine string (rank+name), so identical
// plates collapse to a single hash lookup after the first resolve. Cleared per-zh
// on learn (invalidate_cache) so a contextual still replaces a cached word-sub.
static bool resolve_name(const char* in, std::string& result){
    if(!in || !*in) return false;
    std::unordered_map<std::string,std::string>& C = g_cfg.pinyin ? g_nameCachePy : g_nameCacheEn;
    std::string key(in);
    auto it = C.find(key);
    if(it != C.end()){
        CNFIX_PERF_INC(g_pc_name_hit);
        if(it->second.empty()) return false;   // cached negative
        result = it->second; return true;       // cached positive
    }
    CNFIX_PERF_INC(g_pc_name_miss);
    std::string out;
    bool ok = resolve_name_uncached(in, out);
    C[key] = ok ? out : std::string();          // store positive value or negative sentinel
    if(ok){ result = out; return true; }
    return false;
}
typedef char* (__fastcall* fmt_t)(void* thisU, void* edx, char* dest, int size, int flag, int* outFlag);
static fmt_t o_overhead=nullptr;
static __thread int g_oDepth=0;
static char* __fastcall hk_overhead(void* thisU, void* edx, char* dest, int size, int flag, int* outFlag){
    char* ret = o_overhead(thisU, edx, dest, size, flag, outFlag);   // engine fills dest
    if(g_oDepth>0) return ret;
    if(!g_cfg.master || !g_cfg.overhead) return ret;                 // toggle off -> original Chinese
    g_oDepth++;
    uintptr_t ra0=(uintptr_t)__builtin_return_address(0);
    bool overhead = (ra0>=0x00608f50 && ra0<0x00609210);             // overhead composer ONLY (not tooltip/PVPName)
    if(overhead && dest && size>0 && !IsBadReadPtr(dest,1)){
        char buf[512]; size_t n=0; while(n<sizeof(buf)-1 && dest[n]){ buf[n]=dest[n]; ++n; } buf[n]=0;
        if(has_cjk(buf) && valid_utf8(buf)){
            CNFIX_PERF_INC(g_pc_overhead);
            std::string tr;
            if(resolve_name(buf,tr)){                                // translated -> append marker
                CNFIX_PERF_INC(g_pc_overhead_tx);
                if(tr.empty()||tr[tr.size()-1]!='*') tr.push_back('*');   // marker, no double
                if((int)tr.size() < size) memcpy(dest,tr.c_str(),tr.size()+1);
            }
            cnfix_perf_maybe_dump();
        }
    }
    g_oDepth--;
    return ret;
}

// ---- guild getter hook (0x6094c0): char* __fastcall(this). Returns an
// engine-owned guild-name pointer, so we cannot write in place; return a
// translated copy from a rotating ring buffer. Scoped to the OVERHEAD caller
// only (0x529fe0 tooltip passes through to WoWTranslate). Marker appended like
// overhead names so a translated <Guild> tag reads "<Nirvana*>". ----
typedef char* (__fastcall* guild_t)(void* thisU, void* edx);
static guild_t o_guild=nullptr;
static const int GRING=8, GRLEN=96;
static char g_gring[GRING][GRLEN];
static volatile LONG g_gridx=0;
static char* __fastcall hk_guild(void* thisU, void* edx){
    char* g = o_guild(thisU, edx);
    if(g_oDepth>0 || !g) return g;
    if(!g_cfg.master || !g_cfg.overhead) return g;          // same toggle as overhead names
    uintptr_t ra0=(uintptr_t)__builtin_return_address(0);
    if(ra0<0x00608f50 || ra0>=0x00609210) return g;         // overhead composer only
    if(IsBadReadPtr(g,1)) return g;
    g_oDepth++;
    char* ret=g;
    char buf[GRLEN]; size_t n=0; while(n<sizeof(buf)-1 && g[n]){ buf[n]=g[n]; ++n; } buf[n]=0;
    if(has_cjk(buf) && valid_utf8(buf)){
        CNFIX_PERF_INC(g_pc_guild);
        std::string tr;
        if(resolve_name(buf,tr)){
            if(tr.empty()||tr[tr.size()-1]!='*') tr.push_back('*');
            if(tr.size()<GRLEN){
                LONG i=(InterlockedIncrement(&g_gridx)-1)&(GRING-1);
                memcpy(g_gring[i],tr.c_str(),tr.size()+1); ret=g_gring[i];
            }
        }
    }
    g_oDepth--;
    return ret;
}
// ---- NPC subname getter hook (0x5e09f0): char* __fastcall(this). Returns the
// creature's <subname>/title (the engine-owned string drawn under an NPC's
// overhead name, e.g. <老干部活动中心>). Same shape as the guild getter: copy out,
// translate via resolve_name, return a ring-buffer copy with the "*" marker.
// It has a SINGLE caller -- the overhead builder FUN_00608f50 -- so tooltips are
// unaffected; we still scope to the overhead range defensively. ----
typedef char* (__fastcall* subname_t)(void* thisU, void* edx);
static subname_t o_subname=nullptr;
static char g_sring[GRING][GRLEN];
static volatile LONG g_sridx=0;
static char* __fastcall hk_subname(void* thisU, void* edx){
    char* s = o_subname(thisU, edx);
    if(g_oDepth>0 || !s) return s;
    if(!g_cfg.master || !g_cfg.overhead) return s;          // same toggle as overhead names
    uintptr_t ra0=(uintptr_t)__builtin_return_address(0);
    if(ra0<0x00608f50 || ra0>=0x00609210) return s;         // overhead composer only
    if(IsBadReadPtr(s,1)) return s;
    g_oDepth++;
    char* ret=s;
    char buf[GRLEN]; size_t n=0; while(n<sizeof(buf)-1 && s[n]){ buf[n]=s[n]; ++n; } buf[n]=0;
    if(has_cjk(buf) && valid_utf8(buf)){
        // Dedicated subname path: subnames are SENTENCES (e.g. "Owner's Minion",
        // "Mushroom Vendor") with the OWNER name embedded inside an English
        // template. We CANNOT pass through camel_overhead_name() -- that strips
        // spaces/apostrophes and produces "OwnerSMinion". Instead, byte-walk the
        // string and translate each CJK run inline (preferring learned -> compose
        // fallback), preserving every ASCII byte verbatim. No "*" marker here:
        // it would clutter the "<...>" tag the engine wraps around us.
        std::string r, run;
        auto flush=[&](){
            if(run.empty()) return;
            std::string en;
            if(name_whole(run,en) && !en.empty() && !has_cjk(en.c_str()) && valid_utf8(en.c_str())){
                r+=en;
            } else {
                std::string c=compose_name(run.c_str());
                if(!c.empty() && !has_cjk(c.c_str())){
                    r+=c;
                } else {
                    // compose_name's last-resort path appends raw CJK if a char
                    // misses every map. Romanize as a final guaranteed-ASCII
                    // de-Sinifier so "<Owner's Minion>" works even for owner
                    // names CNFix has never seen (i.e. pet of a non-targeted
                    // player). Always better to show "BuRuiErDeYe's Minion"
                    // than the raw Chinese.
                    std::string py=romanize_pinyin(run);
                    if(!py.empty() && !has_cjk(py.c_str())) r+=py; else r+=run;
                }
            }
            run.clear();
        };
        const unsigned char* p=(const unsigned char*)buf;
        while(*p){
            if(*p>=0xE0 && *p<=0xEF && p[1] && p[2]){
                run.append((const char*)p,3); p+=3;
            } else {
                flush(); r.push_back((char)*p); ++p;
            }
        }
        flush();
        // Only commit if we actually de-Sinified something AND the result fits.
        if(!r.empty() && !has_cjk(r.c_str()) && r != buf && r.size()<GRLEN-1 && valid_utf8(r.c_str())){
            LONG i=(InterlockedIncrement(&g_sridx)-1)&(GRING-1);
            memcpy(g_sring[i],r.c_str(),r.size()+1); ret=g_sring[i];
        }
    }
    g_oDepth--;
    return ret;
}
// ---- "Caller name" / unit title getter hook (0x609210). Two distinct call
// shapes in the overhead pipeline:
//   1) FUN_00608f50 (overhead composer) calls with NON-NULL outPtr; the engine
//      reads *outPtr as the displayed string. We translate *outPtr in place
//      and redirect it to our ring buffer.
//   2) FUN_00609370 (banner formatter) calls with NULL outPtr; the engine
//      uses the RETURN value directly as a sprintf arg to build the
//      "<Owner>'s Minion" template for pets/companions. Without translating
//      the return, the owner name stays Chinese in the assembled banner --
//      which is exactly the lingering pet-name bug.
// So we cover BOTH: scope widened to include the banner formatter, and we
// translate the return value as well as *outPtr. Same byte-walk +
// name_whole / compose / pinyin cascade as hk_subname / resolve_name. ----
typedef char* (__fastcall* callername_t)(void* thisU, void* edx, int* outPtr);
static callername_t o_callername=nullptr;
static char g_cring[GRING][GRLEN];
static volatile LONG g_cridx=0;
static bool cnfix_translate_run(const char* s, std::string& out){
    if(!s) return false;
    char buf[GRLEN]; size_t n=0; while(n<sizeof(buf)-1 && s[n]){ buf[n]=s[n]; ++n; } buf[n]=0;
    if(!has_cjk(buf) || !valid_utf8(buf)) return false;
    std::string r, run;
    auto flush=[&](){
        if(run.empty()) return;
        std::string en;
        if(name_whole(run,en) && !en.empty() && !has_cjk(en.c_str()) && valid_utf8(en.c_str())){
            r+=en;
        } else {
            std::string c=compose_name(run.c_str());
            if(!c.empty() && !has_cjk(c.c_str())){
                r+=c;
            } else {
                std::string py=romanize_pinyin(run);
                if(!py.empty() && !has_cjk(py.c_str())) r+=py; else r+=run;
            }
        }
        run.clear();
    };
    const unsigned char* p=(const unsigned char*)buf;
    while(*p){
        if(*p>=0xE0 && *p<=0xEF && p[1] && p[2]){
            run.append((const char*)p,3); p+=3;
        } else {
            flush(); r.push_back((char)*p); ++p;
        }
    }
    flush();
    if(r.empty() || has_cjk(r.c_str()) || r==buf || r.size()>=GRLEN-1 || !valid_utf8(r.c_str())) return false;
    out = r;
    return true;
}
static char* __fastcall hk_callername(void* thisU, void* edx, int* outPtr){
    char* ret = o_callername(thisU, edx, outPtr);
    if(g_oDepth>0) return ret;
    if(!g_cfg.master || !g_cfg.overhead) return ret;
    uintptr_t ra0=(uintptr_t)__builtin_return_address(0);
    // PET / COMPANION OWNER NAMES (the long-standing miss):
    // FUN_0052fd30 [0x52fd30, 0x52fe90) is the template builder for
    // "<Owner's Minion>" / "<Owner's Pet>" floats on hunter pets, warlock
    // summons, and other player-owned creatures. Confirmed via Ghidra:
    // it reads the pet's owner-GUID from this->+0x110+(0x10/0x14 or 0x20/0x24),
    // resolves the OWNER unit through FUN_00468460(..., 0xb76), then calls
    // FUN_00609210(owner_unit, NULL) -- the return is the OWNER's display
    // name, which sprintf's into a localized "%s's <class>" template.
    bool inOverhead = (ra0 >= 0x00608f50 && ra0 < 0x006094c0);
    bool inPetTpl   = (ra0 >= 0x0052fd30 && ra0 < 0x0052fe90);
    if(!inOverhead && !inPetTpl) return ret;
    g_oDepth++;
    char* newRet = ret;
    // Path A: *outPtr is the displayed string (composer)
    if(outPtr && !IsBadReadPtr(outPtr,4)){
        char* s = (char*)(uintptr_t)(*outPtr);
        if(s && !IsBadReadPtr(s,1)){
            std::string r;
            if(cnfix_translate_run(s, r)){
                LONG i=(InterlockedIncrement(&g_cridx)-1)&(GRING-1);
                memcpy(g_cring[i], r.c_str(), r.size()+1);
                *outPtr = (int)(uintptr_t)g_cring[i];
            }
        }
    }
    // Path B: return value is the displayed string (banner formatter sprintf arg)
    if(ret && !IsBadReadPtr(ret,1)){
        std::string r;
        bool ok = cnfix_translate_run(ret, r);
        // (v2.5.10+) Diagnostic logging for the pet/companion path so we
        // can empirically verify firing. Only logs when in pet template
        // scope -- the overhead-composer path runs at every name draw and
        // would flood the log.
        if(inPetTpl){
            char preview[64]={0}; size_t n=0;
            for(; n<sizeof(preview)-1 && ret[n]; n++) preview[n]=ret[n];
            wnr_log("hk_callername[petTpl] ra=%08x: zh=\"%s\" -> %s%s",
                (unsigned)ra0, preview,
                ok ? "en=\"" : "(translate FAILED, passing through)",
                ok ? r.c_str() : "");
            if(ok) wnr_log("                                                  ^ \"");
        }
        if(ok){
            LONG i=(InterlockedIncrement(&g_cridx)-1)&(GRING-1);
            memcpy(g_cring[i], r.c_str(), r.size()+1);
            newRet = g_cring[i];
        }
    }
    g_oDepth--;
    return newRet;
}
// ---- Pet / companion OWNER-TEMPLATE hook (0x0052fd30). -----------------------
// Ghidra (this session) traced the lingering "<Owner>'s Minion" / "<Owner>'s Pet"
// untranslated-owner bug to FUN_0052fd30, the template builder the overhead
// composer (FUN_00608f50) calls for player-owned creatures. It:
//   1. resolves the pet's OWNER unit via FUN_00468460(...,0xb76)
//   2. fetches the owner display name via FUN_00609210(owner, outPtr=0)
//   3. sprintf's "<owner>'s Minion" into its output buffer (edx), bounded by the
//      size arg the engine passes (0x80).
// FUN_00609210's RETURN SHAPE varies by unit type: for some units it returns a
// direct char* name (0x60934b: *[owner+0xb30]); for others a STRUCT whose name
// lives at +0x30 (0x609283). Translating that return value (hk_callername) is
// therefore unreliable here -- which is exactly why the owner kept rendering in
// Chinese. The ROBUST fix is to translate FUN_0052fd30's FINAL formatted buffer
// in place: we own the bytes, the engine told us the capacity, and the English
// template ("'s Minion") is preserved verbatim while only the CJK run (the owner
// name) is de-Sinified -- via the same name_whole -> compose -> pinyin cascade as
// hk_subname, so the owner reads identically to every other surface (and picks up
// WoWTranslate's contextual once it lands in g_learned).
// __fastcall(ecx=pet, edx=outBuf, stack=cap); RET 0x4. Single caller (FUN_00608f50).
typedef void (__fastcall* petTpl_t)(void* pet, char* outBuf, int cap);
static petTpl_t o_petTpl=nullptr;
static void __fastcall hk_petTpl(void* pet, char* outBuf, int cap){
    // Hold g_oDepth across the original so the inner getter hooks
    // (hk_callername / hk_subname) stay quiet -- we do the single translation
    // pass on the assembled output, never a half-translated intermediate.
    g_oDepth++;
    o_petTpl(pet, outBuf, cap);
    g_oDepth--;
    if(!g_cfg.master || !g_cfg.overhead) return;
    if(!outBuf || cap<=1 || IsBadReadPtr(outBuf, 1)) return;
    // Read the assembled template into a local sized to the engine's own capacity
    // (cap, the 0x80 the composer passes) rather than GRLEN, so a long owner
    // template is never silently clipped before translation. Bounded by a fixed
    // ceiling for stack safety; cap is always small here (0x80).
    char buf[256]; int rdmax = (cap < (int)sizeof(buf)) ? cap : (int)sizeof(buf);
    int n=0; while(n < rdmax-1 && outBuf[n]){ buf[n]=outBuf[n]; ++n; } buf[n]=0;
    if(!has_cjk(buf) || !valid_utf8(buf)) return;          // already English / nothing to do
    std::string r, run;
    auto flush=[&](){
        if(run.empty()) return;
        std::string en;
        if(g_cfg.pinyin){
            // (v2.7.3) Pinyin mode: romanize the owner run directly so the pet/
            // companion float owner switches to pinyin in lockstep with the Name
            // style radio, exactly like resolve_name() does for the overhead name.
            // Previously this path always took the English cascade, so the owner
            // stayed English (or word-sub) when the user flipped to Pinyin.
            std::string py=romanize_pinyin(run);
            if(!py.empty() && !has_cjk(py.c_str())) en=py; else en=run;
        } else {
            if(name_whole(run,en) && !en.empty() && !has_cjk(en.c_str()) && valid_utf8(en.c_str())) {}
            else { std::string c=compose_name(run.c_str());
                   if(!c.empty() && !has_cjk(c.c_str())) en=c;
                   else { std::string py=romanize_pinyin(run);
                          if(!py.empty() && !has_cjk(py.c_str())) en=py; else en=run; } }
        }
        // (v2.7.1) CamelCase the translated owner-NAME run so the pet/companion
        // float reads "<YesterdayOfEveningWind's Minion>" -- the SAME whitespace-free
        // CamelCase form shown over the owner's head and on their unit frame, instead
        // of the spaced "Yesterday Of Evening Wind". The surrounding ASCII template
        // ("'s Minion", "<", ">") is copied verbatim below; only the name token here
        // is collapsed. tokenize() also drops apostrophes/spaces inside the name.
        r += tokenize(en);
        run.clear();
    };
    const unsigned char* p=(const unsigned char*)buf;
    while(*p){
        if(*p>=0xE0 && *p<=0xEF && p[1] && p[2]){ run.append((const char*)p,3); p+=3; }
        else { flush(); r.push_back((char)*p); ++p; }
    }
    flush();
    // Commit only if we actually de-Sinified, the result fits the engine buffer,
    // and it's clean UTF-8 (crash guard).
    if(!r.empty() && !has_cjk(r.c_str()) && r!=buf && (int)r.size() < cap && valid_utf8(r.c_str())){
        memcpy(outBuf, r.c_str(), r.size()+1);
    }
}

// ================= FLOATING NAME SIZE SCALER =================
// Scales the overhead/floating name size by a user-configurable factor.
//
// HOW IT WORKS:
// The WoW 1.12.1 (5875) client renders overhead names in FUN_006c6e90.
// The function computes a scale factor (local_8):
//   - Close range (dist <= 4.0): local_8 = 0.2f
//   - Far range  (dist >  4.0): local_8 = (dist / 4.0) * 1.5 * 0.2
//
// Assembly layout (Ghidra-confirmed for build 5875):
//   006c6f16  MOV [EBP+local_8], 0x3e4ccccd    ; 0.2f immediate (close-range default)
//   006c6f1d  FCOM [DAT_008112a8]               ; compare with 4.0f
//   006c6f2a  FDIV [DAT_008112a8]               ; divide by 4.0f
//   006c6f30  FMUL [DAT_008112ac]               ; multiply by 1.5f
//   006c6f36  FMUL [DAT_0080679c]               ; multiply by 0.2f (.rdata copy)
//
// Three independent user sliders map to these constants:
//   Name Scale   → 0.2f (immediate + .rdata): overall name SIZE
//   Range        → 4.0f (.rdata): how FAR names stay at full size
//   Dist Growth  → 1.5f (.rdata): how FAST names grow beyond threshold
//
// The 0.2f immediate is found by pattern-scanning the function body.
// The .rdata constants are at hardcoded addresses with value validation
// (self-gating: mismatch = dormant, stable build unaffected).
//
// SAFETY: VirtualProtect for write access; original values restored on detach.

// ---- Pattern scan: 0.2f immediate embedded in the function body ----
static const uintptr_t FN_FUNC_ADDR = 0x006c6e90;
static const size_t    FN_FUNC_SIZE = 0x600;
static const unsigned char FN_BASE_PATTERN[4] = { 0xCD, 0xCC, 0x4C, 0x3E }; // 0.2f

// ---- Hardcoded .rdata addresses (Ghidra-confirmed for build 5875) ----
// Each has an expected value for validation. If the value doesn't match
// (wrong client build), that slot is skipped and the slider becomes a no-op.

// 4.0f distance threshold: used in FCOM (comparison) and FDIV (division).
static const uintptr_t FN_RDATA_THRESH = 0x008112a8;
static const float     FN_RDATA_THRESH_EXPECTED = 4.0f;

// 1.5f distance growth multiplier: used in FMUL after the FDIV.
static const uintptr_t FN_RDATA_DISTMUL = 0x008112ac;
static const float     FN_RDATA_DISTMUL_EXPECTED = 1.5f;

// 0.2f base scale (.rdata copy): used in the final FMUL of the distance formula.
static const uintptr_t FN_RDATA_BASE = 0x0080679c;
static const float     FN_RDATA_BASE_EXPECTED = 0.2f;

// ---- Patch slots ----
struct FnPatchSlot {
    uintptr_t addr;
    float     origFloat;
};
static const int FN_MAX_SLOTS = 4;

// 0.2f instances (both the immediate in code and the .rdata copy)
static FnPatchSlot g_fnBaseSlots[FN_MAX_SLOTS];
static int         g_fnBaseCount = 0;

// 4.0f threshold (.rdata)
static FnPatchSlot g_fnThreshSlots[1];
static int         g_fnThreshCount = 0;

// 1.5f distance multiplier (.rdata)
static FnPatchSlot g_fnDistSlots[1];
static int         g_fnDistCount = 0;

static bool g_fnPatched = false;

// Scan a memory range for a 4-byte pattern.
static int fn_scan_pattern(uintptr_t start, size_t len,
                           const unsigned char pattern[4],
                           uintptr_t* out, int maxOut){
    int found = 0;
    const unsigned char* p = (const unsigned char*)start;
    for(size_t i = 0; i + 3 < len && found < maxOut; ++i){
        if(p[i] == pattern[0] && p[i+1] == pattern[1]
           && p[i+2] == pattern[2] && p[i+3] == pattern[3]){
            out[found++] = start + i;
        }
    }
    return found;
}

// Validate a .rdata address: readable and value matches expected.
static bool fn_validate_rdata(uintptr_t addr, float expected, const char* label){
    if(IsBadReadPtr((void*)addr, sizeof(float))){
        wnr_log("nameScale: %s @ 0x%08X unreadable -> skipped", label, (unsigned)addr);
        return false;
    }
    float val = *(float*)addr;
    if(fabs(val - expected) > 0.01f){
        wnr_log("nameScale: %s @ 0x%08X mismatch: got %.2f, expected %.2f -> skipped",
                label, (unsigned)addr, val, expected);
        return false;
    }
    return true;
}

// Write a float to a code/data address using VirtualProtect.
static bool fn_write_float(uintptr_t addr, float val){
    if(IsBadReadPtr((void*)addr, sizeof(float))) return false;
    DWORD oldProtect;
    if(!VirtualProtect((void*)addr, sizeof(float), PAGE_READWRITE, &oldProtect))
        return false;
    *(float*)addr = val;
    VirtualProtect((void*)addr, sizeof(float), oldProtect, &oldProtect);
    return true;
}

// Apply the current scale to all discovered constant slots.
// Three independent multipliers:
//   nameScale   → 0.2f: controls overall name SIZE
//   nameThresh  → 4.0f: controls how FAR names stay full-size
//   nameDistMul → 1.5f: controls how FAST names grow with distance
static void fn_apply_scale(){
    if(!g_fnPatched) return;
    float s = g_cfg.nameScale;
    if(s < 0.1f) s = 0.1f;
    if(s > 5.0f) s = 5.0f;
    float ts = g_cfg.nameThresh;
    if(ts < 0.1f) ts = 0.1f;
    if(ts > 5.0f) ts = 5.0f;
    float ds = g_cfg.nameDistMul;
    if(ds < 0.1f) ds = 0.1f;
    if(ds > 5.0f) ds = 5.0f;
    for(int i = 0; i < g_fnBaseCount; ++i){
        float newVal = g_fnBaseSlots[i].origFloat * s;
        wnr_log("nameScale: patching base[%d] @ 0x%08X: %.2f * %.2f = %.2f", 
                i, (unsigned)g_fnBaseSlots[i].addr, g_fnBaseSlots[i].origFloat, s, newVal);
        fn_write_float(g_fnBaseSlots[i].addr, newVal);
    }
    for(int i = 0; i < g_fnThreshCount; ++i){
        float newVal = g_fnThreshSlots[i].origFloat * ts;
        wnr_log("nameScale: patching thresh[%d] @ 0x%08X: %.2f * %.2f = %.2f",
                i, (unsigned)g_fnThreshSlots[i].addr, g_fnThreshSlots[i].origFloat, ts, newVal);
        fn_write_float(g_fnThreshSlots[i].addr, newVal);
    }
    for(int i = 0; i < g_fnDistCount; ++i){
        float newVal = g_fnDistSlots[i].origFloat * ds;
        wnr_log("nameScale: patching dist[%d] @ 0x%08X: %.2f * %.2f = %.2f",
                i, (unsigned)g_fnDistSlots[i].addr, g_fnDistSlots[i].origFloat, ds, newVal);
        fn_write_float(g_fnDistSlots[i].addr, newVal);
    }
    wnr_log("nameScale: applied scale=%.2f thresh=%.2f dist=%.2f", s, ts, ds);
}

// Restore the original constant values. Called on DLL detach.
static void fn_restore(){
    if(!g_fnPatched) return;
    for(int i = 0; i < g_fnBaseCount; ++i)
        fn_write_float(g_fnBaseSlots[i].addr, g_fnBaseSlots[i].origFloat);
    for(int i = 0; i < g_fnThreshCount; ++i)
        fn_write_float(g_fnThreshSlots[i].addr, g_fnThreshSlots[i].origFloat);
    for(int i = 0; i < g_fnDistCount; ++i)
        fn_write_float(g_fnDistSlots[i].addr, g_fnDistSlots[i].origFloat);
    g_fnPatched = false;
    wnr_log("nameScale: restored original constants");
}

// Install the scaler: scan for 0.2f immediate, validate .rdata addresses.
static void fn_install(){
    if(IsBadReadPtr((void*)FN_FUNC_ADDR, 16)){
        wnr_log("nameScale: overhead renderer @0x%08X unreadable -> DORMANT", (unsigned)FN_FUNC_ADDR);
        return;
    }
    // 1) Pattern-scan the function body for the 0.2f immediate.
    uintptr_t baseHits[FN_MAX_SLOTS];
    g_fnBaseCount = fn_scan_pattern(FN_FUNC_ADDR, FN_FUNC_SIZE,
                                     FN_BASE_PATTERN, baseHits, FN_MAX_SLOTS);
    if(g_fnBaseCount == 0){
        wnr_log("nameScale: 0.2f immediate NOT found -> DORMANT (stable build unaffected)");
        return;
    }
    for(int i = 0; i < g_fnBaseCount; ++i){
        g_fnBaseSlots[i].addr = baseHits[i];
        g_fnBaseSlots[i].origFloat = *(float*)baseHits[i];
    }

    // 2) Validate and add the .rdata copy of 0.2f (used in FMUL).
    if(fn_validate_rdata(FN_RDATA_BASE, FN_RDATA_BASE_EXPECTED, "0.2f rdata")){
        g_fnBaseSlots[g_fnBaseCount].addr = FN_RDATA_BASE;
        g_fnBaseSlots[g_fnBaseCount].origFloat = *(float*)FN_RDATA_BASE;
        g_fnBaseCount++;
    }

    // 3) Add the 4.0f threshold (FCOM + FDIV) - skip validation, trust the address
    if(!IsBadReadPtr((void*)FN_RDATA_THRESH, sizeof(float))){
        g_fnThreshSlots[0].addr = FN_RDATA_THRESH;
        g_fnThreshSlots[0].origFloat = *(float*)FN_RDATA_THRESH;
        g_fnThreshCount = 1;
        wnr_log("nameScale: 4.0f thresh @ 0x%08X = %.2f", (unsigned)FN_RDATA_THRESH, g_fnThreshSlots[0].origFloat);
    }

    // 4) Add the 1.5f distance multiplier (FMUL) - skip validation, trust the address
    if(!IsBadReadPtr((void*)FN_RDATA_DISTMUL, sizeof(float))){
        g_fnDistSlots[0].addr = FN_RDATA_DISTMUL;
        g_fnDistSlots[0].origFloat = *(float*)FN_RDATA_DISTMUL;
        g_fnDistCount = 1;
        wnr_log("nameScale: 1.5f dist @ 0x%08X = %.2f", (unsigned)FN_RDATA_DISTMUL, g_fnDistSlots[0].origFloat);
    }

    g_fnPatched = true;
    if(g_cfg.nameScale != 1.0f || g_cfg.nameThresh != 1.0f || g_cfg.nameDistMul != 1.0f)
        fn_apply_scale();
    wnr_log("nameScale: ARMED (%d x 0.2f + %d x 4.0f + %d x 1.5f, scale=%.2f thresh=%.2f dist=%.2f)",
            g_fnBaseCount, g_fnThreshCount, g_fnDistCount,
            g_cfg.nameScale, g_cfg.nameThresh, g_cfg.nameDistMul);
}

static const WnrSig kSig[] = {
    {0x0079D760,{0xa1,0xcc,0x2c,0xcf,0x00,0x85,0xc0,0x56},"SetText"},
    {0x0048A420,{0x55,0x8b,0xec,0x83,0xec,0x18,0x56,0x57},"InviteByName"},
    {0x0048AEF0,{0x55,0x8b,0xec,0x83,0xec,0x18,0x53,0x56},"GuildInviteByName"},
    {0x0048A3B0,{0x56,0x57,0xba,0x01,0x00,0x00,0x00,0x8b},"InviteToParty"},
    {0x005AD290,{0x56,0xba,0x01,0x00,0x00,0x00,0x8b,0xf1},"AddFriend"},
    {0x0048A120,{0x56,0x57,0xba,0x01,0x00,0x00,0x00,0x8b},"InitiateTrade"},
    {0x00489D60,{0x56,0x57,0xba,0x01,0x00,0x00,0x00,0x8b},"TargetByName"},
    {0x004AE800,{0x55,0x8b,0xec,0x83,0xec,0x44,0x53,0x56},"SendMail"},
    {0x0049F1E0,{0x53,0x8b,0xdc,0x83,0xec,0x08,0x83,0xe4},"SendChatMessage"},
    {0x006F3690,{0x56,0x57,0x8b,0xf9,0xe8,0x77,0xfd,0xff},"lua_tostring"},
    {0x006F3890,{0x85,0xd2,0x56,0x8b,0xf1,0x75,0x06,0x5e},"lua_pushstring"},
    {0x006F30D0,{0x85,0xd2,0x56,0x7e,0x0c,0x8b,0x41,0x0c},"lua_remove"},
    {0x006F31A0,{0x55,0x8b,0xec,0x51,0x85,0xd2,0x56,0x57},"lua_insert"},
};
static DWORD WINAPI wtf_thread(LPVOID){
    for(;;){ scan_wtf_and_learn(); Sleep(5000); } return 0;
}
static void purge_glossary_dupes(){
    // Guarantee glossary supremacy: drop any glossary key from the other maps.
    for(auto& kv : g_wtg){
        g_cedict.erase(kv.first);
        g_chars.erase(kv.first);
        auto it=g_learned.find(kv.first);
        if(it!=g_learned.end()){ g_learned.erase(it); }
        g_cache.erase(kv.first);   // clear any stale cached value for a glossary key
    }
}
// ===========================================================================
// (v2.5.8+) DEEP C++ SetText HOOK -- catches non-Lua paths
// ===========================================================================
// The Lua glue at 0x0079D760 is one entry point to FontString text mutation.
// 1.12 engine code also calls the underlying C++ method directly for things
// like tooltip line population, nameplate updates, world-string overlays,
// etc. Those paths bypass the Lua wrapper and so bypass our existing hook.
//
// STRATEGY
// 1. At runtime, scan the Lua glue function for direct E8 CALL instructions.
// 2. Exclude calls into the Lua helper address range (those are
//    lua_tostring / lua_pushstring / etc.) -- we know their signatures and
//    they're not SetText.
// 3. Of the remaining candidates, the LAST direct CALL before RET is the
//    most likely C++ SetText invocation (typical compiler codegen for a
//    wrapper that validates args then dispatches to the worker).
// 4. Sanity-check the candidate's prologue before installing -- if it
//    doesn't look like a function entry, bail.
// 5. Install MinHook on the candidate. The hook applies the SAME surface
//    gates as the Lua glue hook, but at the C++ level so engine internal
//    callers are also caught.
//
// SAFETY
// - Gated on g_cfg.deepHook (off by default). Users opt in.
// - If discovery is ambiguous (zero or >3 candidates) we bail without
//   installing.
// - Prologue check rejects targets that don't look like function entries.
// - (v2.7.0) The leaf no longer sets g_cpp_hook_active; it self-restricts to
//   the tooltip-name / nameplate surfaces it owns (see hk_setText_cpp), so the
//   Lua glue keeps doing translate_preserving for every other surface. The two
//   are idempotent on owned surfaces (glue output has no CJK -> leaf no-ops).
// - Recursion guard on the hook itself prevents nested calls during
//   GetName / o_setText_cpp invocation.

// (v2.5.9+) The Lua glue at 0x0079D760 was confirmed via Ghidra to dispatch
// to FUN_00771d80 -- the C++ FontString::SetText leaf method (__thiscall,
// signature `void (this, const char* text, int processMarkup)`, RET 0x8).
// 16 verified callsites across the engine's chat, tooltip, frame, and
// scripting subsystems; this is unambiguously the universal text-write
// sink for 2D FontStrings. No more discovery heuristic -- the address is
// pinned with a 13-byte prologue signature gate that bails safely on any
// recompiled / patched client where the bytes don't match.
//
// (3D overhead names DO NOT go through this leaf -- they bypass FontString
// entirely and render directly through the GL pipeline at FUN_007716f0
// invoked from FUN_006c6e90. Those surfaces continue to be handled by the
// hk_overhead / hk_subname / hk_callername / hk_guild hooks on the C++
// getter functions, not by this SetText hook.)
static const uintptr_t SETTEXT_CPP_ADDR = 0x00771D80;
static const unsigned char SETTEXT_CPP_SIG[13] = {
    0x55,             // push ebp
    0x8B, 0xEC,       // mov  ebp, esp
    0x53,             // push ebx
    0x56,             // push esi
    0x57,             // push edi
    0x8B, 0x7D, 0x08, // mov  edi, [ebp+0x8]    (text arg)
    0x85, 0xFF,       // test edi, edi
    0x8B, 0xF1        // mov  esi, ecx          (this -> esi)
};

// __thiscall(this, const char* text, int processMarkup) -- declared as
// __fastcall(ecx=this, edx=unused, stack=text, flag). Ghidra-verified
// param layout matches this; the trailing RET 0x8 cleans the two stack args.
typedef int (__fastcall* setTextCpp_t)(void* fs, void* edx, const char* text, int processMarkup);
static setTextCpp_t o_setText_cpp = nullptr;

// Recursion guard for the C++ hook. __thread for per-thread safety; the
// engine is single-threaded but better safe than sorry.
static __thread bool t_in_cpp_hook = false;

// Thread-local translation buffer. SetText copies the text into the
// FontString's own storage, so this buffer only needs to live for the
// duration of the original call.
static __thread char t_cpp_tx_buf[1024];

static int __fastcall hk_setText_cpp(void* fs, void* edx, const char* text, int processMarkup){
    // Bail safely if anything looks off.
    if(t_in_cpp_hook || !fs || !text || IsBadReadPtr(text, 1)){
        return o_setText_cpp(fs, edx, text, processMarkup);
    }
    if(!g_cfg.master){
        return o_setText_cpp(fs, edx, text, processMarkup);
    }
    // Quick reject: no CJK = no translation work to do, fast path.
    if(!has_cjk(text)){
        return o_setText_cpp(fs, edx, text, processMarkup);
    }
    CNFIX_PERF_INC(g_pc_setcpp);
    // Resolve frame name via vtable. Same as wnr_target_should_skip but
    // direct: no Lua state needed.
    void** vtbl = *(void***)fs;
    if(!vtbl || IsBadReadPtr(vtbl, 8)){
        return o_setText_cpp(fs, edx, text, processMarkup);
    }
    void* getName = vtbl[1];   // slot +4
    if(!getName || IsBadCodePtr((FARPROC)getName)){
        return o_setText_cpp(fs, edx, text, processMarkup);
    }
    t_in_cpp_hook = true;
    const char* frame_name = ((WnrGetName_t)getName)(fs);
    t_in_cpp_hook = false;
    if(!frame_name || IsBadReadPtr(frame_name, 1)){
        return o_setText_cpp(fs, edx, text, processMarkup);
    }
    // (v2.7.1) The leaf translates ONLY the tooltip NAME line. Nameplates are
    // deliberately NOT owned here: routing them through this non-caching leaf made
    // a plate stick on the first-rendered word-sub (compose) translation, because
    // once the leaf wrote English the FontString no longer held CJK, so neither the
    // engine's next write nor the addon enforcer could upgrade it to WoWTranslate's
    // contextual without a /reload or toggle. Nameplates instead flow through the
    // Lua glue's translate_preserving -- which CACHES via resolve() and is
    // INVALIDATED the instant a contextual is learned (learn() -> invalidate_cache)
    // -- exactly the fast path the last public build used. The Lua npEnforceFS
    // backstop re-asserts any plate the engine reverts to Chinese.
    bool isTooltipName = (strcmp(frame_name, "GameTooltipTextLeft1") == 0);
    bool owned = (isTooltipName && g_surface_tooltipName);
    if(!owned){
        return o_setText_cpp(fs, edx, text, processMarkup);
    }
    // Belt-and-braces: still honor the full skip table (e.g. tooltip body off).
    if(wnr_target_should_skip_by_name(frame_name)){
        return o_setText_cpp(fs, edx, text, processMarkup);
    }
    // Translate. Use the same cnfix_translate_run cascade as hk_callername
    // (name_whole -> compose -> pinyin) for consistency.
    t_in_cpp_hook = true;
    std::string translated;
    bool ok = cnfix_translate_run(text, translated);
    t_in_cpp_hook = false;
    if(!ok || translated.empty()){
        return o_setText_cpp(fs, edx, text, processMarkup);
    }
    // (v2.7.4) Tooltip name line: CamelCase the NAME but PRESERVE a leading ASCII
    // rank/title ("Scout ", "Senior Sergeant ") with its space, exactly like the
    // overhead/frame path (resolve_name -> camel_overhead_name). Tokenizing the
    // WHOLE string collapsed "Senior Sergeant GoldWater" -> "SeniorSergeantGoldWater";
    // instead we measure the leading-ASCII prefix of the SOURCE text (the rank,
    // which translate passes through verbatim so its byte length is unchanged in the
    // result) and CamelCase only the de-Sinified name part after it.
    size_t pfx=0; while(text[pfx] && (unsigned char)text[pfx]<0x80) pfx++;  // leading ASCII rank
    std::string camel = camel_overhead_name(translated, pfx);
    if(camel.empty() || camel.size() >= sizeof(t_cpp_tx_buf) - 1){
        return o_setText_cpp(fs, edx, text, processMarkup);
    }
    memcpy(t_cpp_tx_buf, camel.c_str(), camel.size() + 1);
    return o_setText_cpp(fs, edx, t_cpp_tx_buf, processMarkup);
}

// (v2.5.9+) Direct install at the Ghidra-confirmed leaf address with a
// strict 13-byte prologue signature gate. No more discovery scan, no more
// candidate ranking -- the address is locked in.
static bool maybe_install_deep_hook(){
    // (v2.7.0) The deep C++ leaf hook is now the ENGINE-LEVEL mechanism behind
    // the clean "Tooltips" toggle. Tooltip lines are populated by the engine's
    // C++ FontString::SetText (0x00771D80), NOT the Lua glue (0x0079D760), so the
    // glue hook alone can never translate them -- this leaf is required. It is
    // installed whenever the 13-byte signature matches; it stays INERT unless a
    // surface flag (g_surface_tooltipName / tooltipBody / nameplates) is on,
    // because wnr_target_should_skip_by_name() gates every call by surface. The
    // old separate "Deep SetText hook" UI toggle (g_cfg.deepHook) is gone; the
    // surface toggles are the only control surface now.
    if(IsBadReadPtr((LPCVOID)SETTEXT_CPP_ADDR, sizeof(SETTEXT_CPP_SIG))){
        wnr_log("deepHook: leaf 0x%08x unreadable, bailing", (unsigned)SETTEXT_CPP_ADDR);
        return false;
    }
    if(memcmp((const void*)SETTEXT_CPP_ADDR, SETTEXT_CPP_SIG, sizeof(SETTEXT_CPP_SIG)) != 0){
        wnr_log("deepHook: leaf 0x%08x SIG mismatch (recompiled/patched client?), bailing",
            (unsigned)SETTEXT_CPP_ADDR);
        return false;
    }
    if(MH_CreateHook((LPVOID)SETTEXT_CPP_ADDR, (LPVOID)&hk_setText_cpp,
                     (LPVOID*)&o_setText_cpp) != MH_OK){
        wnr_log("deepHook: MH_CreateHook FAIL on 0x%08x", (unsigned)SETTEXT_CPP_ADDR);
        return false;
    }
    if(MH_EnableHook((LPVOID)SETTEXT_CPP_ADDR) != MH_OK){
        wnr_log("deepHook: MH_EnableHook FAIL on 0x%08x", (unsigned)SETTEXT_CPP_ADDR);
        return false;
    }
    // (v2.7.0 AUDIT FIX) Do NOT set g_cpp_hook_active here. The leaf now
    // self-restricts to the tooltip-name / nameplate surfaces it owns (see
    // hk_setText_cpp), so the Lua glue must keep running translate_preserving
    // for every other surface -- that path is multi-run, escape-aware, and
    // protects |Hplayer link payloads for the action reverse-swap. The two are
    // idempotent on owned surfaces (the glue's English output has no CJK, so the
    // leaf's second pass is a no-op), so leaving the glue fully active is safe.
    wnr_log("deepHook: ARMED on FontString::SetText @0x%08x (Ghidra-confirmed leaf; surface-scoped)",
        (unsigned)SETTEXT_CPP_ADDR);
    return true;
}

static DWORD WINAPI init(LPVOID){
    wnr_log("---- init CNFixEnglish (layered meaning) ----");
    build();
    // learned file lives next to the DLL
    std::string lp=gamedir()+"\\CNFix_learned.txt";
    strncpy(g_learnedPath,lp.c_str(),sizeof(g_learnedPath)-1);
    bool combined=load_combined_file();
    if(!combined){
    // fallback: legacy separate seed files
    std::string wp=gamedir()+"\\CNFix_glossary.txt";
    strncpy(g_wtgPath,wp.c_str(),sizeof(g_wtgPath)-1);
    load_wtg_file();
    std::string cp=gamedir()+"\\CNFix_cedict.txt";
    strncpy(g_cedictPath,cp.c_str(),sizeof(g_cedictPath)-1);
    load_cedict_file();
    std::string chp=gamedir()+"\\CNFix_chars.txt";
    strncpy(g_charsPath,chp.c_str(),sizeof(g_charsPath)-1);
    load_chars_file();
    }
    // ALWAYS load the live, user-grown learned file (it overrides seed data)
    load_learned_file();
    purge_glossary_dupes();   // glossary keys removed from cedict/chars/learned/cache
    wnr_log("loaded: glossary=%zu cedict=%zu chars=%zu learned=%zu", g_wtg.size(), g_cedict.size(), g_chars.size(), g_learned.size());
    { auto it=g_wtg.find(std::string("\xe5\x93\x80\xe5\x8f\xb7")); // 哀号
      wnr_log("self-test: glossary['哀号'] = %s", it!=g_wtg.end()?it->second.c_str():"(MISSING - data not loaded!)"); }
    if(!wnr_validate(kSig,(int)(sizeof(kSig)/sizeof(kSig[0])))){
        wnr_log("DISABLED: client signatures did not match - no hooks installed (safe).");
        return 0;
    }
    wnr_install_veh();
    if(MH_Initialize()!=MH_OK){ wnr_log("MH_Initialize FAILED"); return 0; }
    wnr_hook((LPVOID)0x0079D760,(LPVOID)&hkGlue,(LPVOID*)&oGlue,"SetText");
    wnr_hook((LPVOID)0x0048A420,(LPVOID)&hk_InviteByName,(LPVOID*)&o_InviteByName,"InviteByName");
    wnr_hook((LPVOID)0x0048AEF0,(LPVOID)&hk_GuildInviteByName,(LPVOID*)&o_GuildInviteByName,"GuildInviteByName");
    wnr_hook((LPVOID)0x0048A3B0,(LPVOID)&hk_InviteToParty,(LPVOID*)&o_InviteToParty,"InviteToParty");
    wnr_hook((LPVOID)0x005AD290,(LPVOID)&hk_AddFriend,(LPVOID*)&o_AddFriend,"AddFriend");
    wnr_hook((LPVOID)0x0048A120,(LPVOID)&hk_InitiateTrade,(LPVOID*)&o_InitiateTrade,"InitiateTrade");
    wnr_hook((LPVOID)0x00489D60,(LPVOID)&hk_TargetByName,(LPVOID*)&o_TargetByName,"TargetByName");
    wnr_hook((LPVOID)0x004AE800,(LPVOID)&hk_SendMail,(LPVOID*)&o_SendMail,"SendMail");
    wnr_hook((LPVOID)0x0049F1E0,(LPVOID)&hk_SendChatMessage,(LPVOID*)&o_SendChatMessage,"SendChatMessage");
    // Overhead/3D floating names: independent gate so a mismatch here never
    // disables core translation (the kSig gate above already passed).
    { static const unsigned char FSIG[8]={0x55,0x8b,0xec,0x83,0xec,0x20,0x8b,0x45};
      if(!IsBadReadPtr((void*)0x00609370,8) && memcmp((const void*)0x00609370,FSIG,8)==0){
          wnr_hook((LPVOID)0x00609370,(LPVOID)&hk_overhead,(LPVOID*)&o_overhead,"OverheadName");
          wnr_log("overhead-name hook ARMED (formatter@609370)");
      } else wnr_log("overhead-name hook SKIPPED (formatter@609370 sig mismatch)");
    }
    // Guild getter (overhead <Guild> tag). Independent gate; tooltip passes through.
    { static const unsigned char GSIG[8]={0x8b,0x81,0x30,0x0b,0x00,0x00,0x85,0xc0};
      if(!IsBadReadPtr((void*)0x006094C0,8) && memcmp((const void*)0x006094C0,GSIG,8)==0){
          wnr_hook((LPVOID)0x006094C0,(LPVOID)&hk_guild,(LPVOID*)&o_guild,"GuildName");
          wnr_log("guild-name hook ARMED (getter@6094c0)");
      } else wnr_log("guild-name hook SKIPPED (getter@6094c0 sig mismatch)");
    }
    // NPC subname getter (overhead <subname> tag). Independent gate; one caller.
    { static const unsigned char SSIG[8]={0x53,0x8b,0xdc,0x83,0xec,0x08,0x83,0xe4};
      if(!IsBadReadPtr((void*)0x005E09F0,8) && memcmp((const void*)0x005E09F0,SSIG,8)==0){
          wnr_hook((LPVOID)0x005E09F0,(LPVOID)&hk_subname,(LPVOID*)&o_subname,"NpcSubname");
          wnr_log("npc-subname hook ARMED (getter@5e09f0)");
      } else wnr_log("npc-subname hook SKIPPED (getter@5e09f0 sig mismatch)");
    }
    // Caller-name / unit-title getter (0x609210). The OTHER subname-shaped
    // string the overhead builder pulls -- the one through which pet "Owner's
    // Minion" templates surface. Hooking it is the symmetric companion to the
    // existing subname/guild hooks; without it, pet owner names stayed Chinese
    // because hk_subname never saw them. Same stack-realigning prologue as
    // FUN_005e09f0 / SendChatMessage: PUSH EBX / MOV EBX,ESP / SUB ESP,8 /
    // AND ESP,0xfffffff8.
    { static const unsigned char CSIG[8]={0x53,0x8b,0xdc,0x83,0xec,0x08,0x83,0xe4};
      if(!IsBadReadPtr((void*)0x00609210,8) && memcmp((const void*)0x00609210,CSIG,8)==0){
          wnr_hook((LPVOID)0x00609210,(LPVOID)&hk_callername,(LPVOID*)&o_callername,"UnitTitle");
          wnr_log("unit-title hook ARMED (getter@609210)");
      } else wnr_log("unit-title hook SKIPPED (getter@609210 sig mismatch)");
    }
    // (v2.7.0) Pet/companion OWNER-TEMPLATE builder (0x0052fd30). Post-translates
    // the assembled "<Owner>'s Minion/Pet" buffer in place -- the robust fix for
    // owner names that stayed Chinese because FUN_00609210's return shape (direct
    // char* vs struct+0x30) defeated the return-value translation in hk_callername.
    // Independent gate; bails on sig mismatch (never disables core translation).
    // Prologue: PUSH EBP / MOV EBP,ESP / SUB ESP,8 / TEST ECX,ECX.
    { static const unsigned char PSIG[8]={0x55,0x8b,0xec,0x83,0xec,0x08,0x85,0xc9};
      if(!IsBadReadPtr((void*)0x0052fd30,8) && memcmp((const void*)0x0052fd30,PSIG,8)==0){
          wnr_hook((LPVOID)0x0052fd30,(LPVOID)&hk_petTpl,(LPVOID*)&o_petTpl,"PetOwnerTemplate");
          wnr_log("pet-owner template hook ARMED (builder@52fd30)");
      } else wnr_log("pet-owner template hook SKIPPED (builder@52fd30 sig mismatch)");
    }
    // Floating name size scaler: patches the overhead name base scale constant.
    // Auto-discovers the 0.2f constant by scanning FUN_006c6e90 at runtime.
    // Self-gating: if the pattern isn't found, stays dormant.
    fn_install();
    // (v2.5.8+) Attempt the deep C++ leaf SetText hook if user opted in.
    maybe_install_deep_hook();
    wnr_log("CNFixEnglish hooks installed: layered meaning swap + 7 action hooks");
    CreateThread(0,0,wtf_thread,0,0,0);
    return 0;
}
BOOL WINAPI DllMain(HINSTANCE h,DWORD r,LPVOID){
    if(r==DLL_PROCESS_ATTACH){ DisableThreadLibraryCalls(h); wnr_log_init(h); wnr_log("attach"); CreateThread(0,0,init,0,0,0); }
    else if(r==DLL_PROCESS_DETACH){ fn_restore(); MH_DisableHook(MH_ALL_HOOKS); MH_Uninitialize(); }
    return TRUE;
}
