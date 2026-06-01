// ===========================================================================
//  CNFix - Broad unit-name hook  ::  PHASE 1 = LOGGING ONLY (no transform)
//  Target : CGUnit::GetName  @ 0x00609210
//  Proto  : char* __thiscall GetName(CGUnit* this, char** outName2)
//           -> player names via name cache, NPC via creature cache,
//              fallback "Unknown Being". This is the ENGINE name getter
//              feeding nameplates, overhead names, unitframes, tooltip,
//              chat-link build, combat log, server-command paths, etc.
//
//  WHAT THIS BUILD DOES: calls the original, then LOGS the returned name +
//  caller return-address + a would-it-transform/block decision + a read-only
//  resolve() preview. It NEVER alters the return value. Identity is preserved.
//
//  WHY A LOCAL GATE (not kSig): adding an unverified entry to kSig would make
//  wnr_validate() fail and disable the whole stable DLL. So GetName self-gates
//  on its own 8 prologue bytes; a mismatch disables ONLY the broad hook.
//
//  THREADING: GetName runs on the main (render/UI) thread only -> no locking,
//  consistent with the project rule "keep map access single-threaded".
//
//  INTEGRATION (3 edits in CNFixEnglish_source.cpp):
//    (1) #include this file (or paste its body) immediately AFTER the
//        hk_SendChatMessage line (~756), BEFORE the kSig[] table.
//    (2) in init(), AFTER the existing wnr_hook(...) calls and before
//        CreateThread(wtf_thread): add   gn_install();
//    (3) build.sh: add  -fno-omit-frame-pointer   (belt+suspenders for the
//        return-address capture; level-0 __builtin_return_address is reliable
//        but this removes all doubt).
//  DO NOT add GetName to kSig. DO NOT touch the 13 stable hooks / resolve /
//  cache. This file only ADDS symbols.
// ===========================================================================

static const uintptr_t GN_ADDR    = 0x00609210;
static const size_t    GN_MAX_LEN = 64;   // 1.12 unit names are <= ~48 bytes

// __thiscall(this[ECX], outName2[stack]) is matched by __fastcall(ECX,EDX,stack)
// with EDX ignored - same register/stack layout and same callee-clean ret 4.
typedef const char* (__fastcall* getname_t)(void* thisUnit, void* edx, char** outName2);
static getname_t o_GetName = nullptr;

// ---- local client gate: 8 prologue bytes at 0x00609210 -------------------
// TODO(fill from Ghidra listing @ 0x00609210, first 8 bytes). While left as
// all-zero, the broad hook stays DORMANT (logs "sig not set") and the stable
// build is completely unaffected.
// 0x609210: PUSH EBX; MOV EBX,ESP; SUB ESP,8; AND ESP,-8  (MSVC stack-align prologue)
static const unsigned char GN_SIG[8] = { 0x53,0x8B,0xDC,0x83,0xEC,0x08,0x83,0xE4 };

static bool gn_sig_set(){ for(int i=0;i<8;++i) if(GN_SIG[i]) return true; return false; }
static bool gn_sig_ok(){
    if(IsBadReadPtr((void*)GN_ADDR,8)) return false;
    return memcmp((const void*)GN_ADDR, GN_SIG, 8)==0;
}

// ---- caller classification (SEED) ----------------------------------------
// Keyed by containing-function start (from Ghidra get_function_xrefs on
// FUN_00609210). Phase-1 uses this only as a *hint label* in the log; it is
// NOT safety-critical here because nothing is transformed. Phase-2's transform
// build will key on the EXACT return addresses harvested from these logs.
enum GnAct { GN_ALLOW, GN_BLOCK, GN_UNKNOWN, GN_FUNNEL };
struct GnSeed { uintptr_t fnStart; uintptr_t fnEnd; const char* subsystem; GnAct act; };
// CONFIRMED via Ghidra this session. GN_FUNNEL = a shared formatter whose grand-
// caller (depth-1 RA) is what actually disambiguates the surface -> classify on ra1.
static const GnSeed kGnSeed[] = {
    { 0x00609370, 0x006094c0, "NAME-FORMATTER(shared funnel - use ra1)", GN_FUNNEL }, // CONFIRMED funnel
    { 0x00608f50, 0x00609210, "OverheadName-compose(world float text)",  GN_ALLOW  }, // CONFIRMED overhead
    { 0x007cb6d0, 0x007cb780, "Nameplate(CGNamePlateFrame::Init)",        GN_ALLOW  }, // CONFIRMED nameplate
    { 0x0048a420, 0x0048a4e0, "InviteByName(server-identity)",            GN_BLOCK  }, // CONFIRMED block
    // depth-1 grand-callers of the formatter still to classify from logs:
    //   0x00529fe0, 0x005172b0  (likely target/tooltip/unitframe) -> see worksheet
};
// .text bounds for this 5875 client (validate captured return addresses)
static inline bool gn_in_text(uintptr_t a){ return a>=0x00401000 && a<0x007ff000; }
static GnAct gn_classify(uintptr_t ra, const char** subOut){
    const GnSeed* best=nullptr;
    for(const auto& s : kGnSeed){
        uintptr_t end = s.fnEnd ? s.fnEnd : s.fnStart + 0x600;   // fallback window
        if(ra >= s.fnStart && ra < end)
            if(!best || s.fnStart > best->fnStart) best=&s;
    }
    if(best){ *subOut=best->subsystem; return best->act; }
    *subOut="?unknown"; return GN_UNKNOWN;
}

// ---- crash-safe copy of the engine name string ---------------------------
static bool gn_safe_name(const char* p, char* out, size_t cap){
    if(!p || IsBadReadPtr(p,1)) return false;
    size_t i=0;
    for(; i+1<cap; ++i){
        if(IsBadReadPtr(p+i,1)) return false;
        char c=p[i];
        if(c=='\0') break;
        out[i]=c;
    }
    out[i]='\0';
    return true;
}

// ---- dedupe + log ---------------------------------------------------------
static std::unordered_set<std::string> g_gnSeen;   // key = "ra|name"
static unsigned long g_gnSeq=0;

static void gn_log(uintptr_t ra0, uintptr_t ra1, const char* name){
    char buf[GN_MAX_LEN];
    bool ok  = gn_safe_name(name, buf, sizeof(buf));
    const char* shown = ok ? buf : "<unreadable>";
    bool cjk = ok && has_cjk(buf);
    bool utf = ok && valid_utf8(buf);

    // classify on the immediate caller; if it's the shared name-formatter
    // (GN_FUNNEL), the surface is decided by the grand-caller (ra1).
    const char* sub=nullptr; GnAct act = gn_classify(ra0,&sub);
    const char* sub1=nullptr;
    if(act==GN_FUNNEL && gn_in_text(ra1)) act = gn_classify(ra1,&sub1);

    char key[200]; snprintf(key,sizeof(key),"%08X|%08X|%s",(unsigned)ra0,(unsigned)ra1,shown);
    if(g_gnSeen.count(key)) return;                 // already logged this triple
    if(g_gnSeen.size()>8000) g_gnSeen.clear();      // bound memory
    g_gnSeen.insert(key);

    const char* decision; std::string preview, source="-";
    if(!ok)            decision="PASS(unreadable)";
    else if(!cjk)      decision="PASS(non-CJK)";
    else if(!utf)      decision="PASS(bad-utf8)";
    else if(act==GN_BLOCK)  decision="WOULD-BLOCK";
    else {
        decision = (act==GN_ALLOW) ? "WOULD-XFORM" : "WOULD-XFORM?(classify ra1)";
        std::string k = strip_fmt(buf); if(k.empty()) k=buf;
        if      (g_wtg.count(k))     source="glossary";
        else if (g_learned.count(k)) source="learned/WT";
        else if (g_cedict.count(k))  source="cedict";
        else                         source="compose/pinyin"; // no contextual hit
        preview = resolve(buf);   // read-only; const std::string& -> copy
    }

    static std::string path = gamedir()+"\\CNFix_getname_log.txt";
    FILE* f=fopen(path.c_str(),"ab");
    if(f){
        fprintf(f,"#%lu ra0=%08X ra1=%08X sub=%-44s cjk=%d utf=%d %-26s name=\"%s\"",
                ++g_gnSeq,(unsigned)ra0,(unsigned)ra1,(sub1?sub1:sub),(int)cjk,(int)utf,decision,shown);
        if(!preview.empty()) fprintf(f," => \"%s\" [%s]",preview.c_str(),source.c_str());
        fputc('\n',f);
        fclose(f);
    }
}

// ---- the detour: PHASE 1 returns the original unchanged -------------------
static const char* __fastcall hk_GetName(void* thisUnit, void* edx, char** outName2){
    const char* name = o_GetName(thisUnit, edx, outName2);     // ORIGINAL first
    uintptr_t ra0 = (uintptr_t)__builtin_return_address(0);    // immediate caller
    uintptr_t ra1 = (uintptr_t)__builtin_return_address(1);    // grand-caller (funnel disambig)
    if(!gn_in_text(ra1)) ra1 = 0;                              // guard garbage walk
    if(g_cfg.master)                                           // respect master toggle
        gn_log(ra0, ra1, name);
    return name;                                               // identity preserved
}

static void gn_install(){
    if(!gn_sig_set()){ wnr_log("GetName broad hook: GN_SIG not set -> DORMANT (stable build unaffected)"); return; }
    if(!gn_sig_ok()) { wnr_log("GetName broad hook: prologue MISMATCH @0x609210 -> disabled (stable build unaffected)"); return; }
    wnr_hook((LPVOID)GN_ADDR,(LPVOID)&hk_GetName,(LPVOID*)&o_GetName,"GetName");
    { std::string p=gamedir()+"\\CNFix_getname_log.txt"; FILE* f=fopen(p.c_str(),"ab");
      if(f){ fprintf(f,"==== CNFix GetName PHASE1 logging start (no transform) ====\n"
                       "legend: ra=caller return addr  sub=guessed subsystem  decision=WOULD-XFORM|WOULD-BLOCK|PASS  =>preview[source]\n"); fclose(f); } }
    wnr_log("GetName broad hook: PHASE1 logging installed @0x609210");
}
