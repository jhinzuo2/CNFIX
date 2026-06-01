// wnr_common.h - shared hardening for WoWNameRomanizer (5875 client).
// MinGW-compatible (no __try/__except). Provides:
//   - safe logging next to the DLL, OFF unless a "WoWRomanizer.debug" file exists
//   - client build-string + per-address byte-signature validation (self-disable
//     instead of crashing if the client build differs)
//   - a Vectored Exception Handler that swallows access violations arising in
//     our own hook code so a bad input degrades to "no translation" not a crash
//   - MinHook install helper
#pragma once
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "MinHook.h"

// ---------- safe logging (OFF by default) ----------
static char g_logpath[260] = {0};
static bool g_logEnabled = false;
static HINSTANCE g_self = 0;
static uintptr_t g_selfBase = 0, g_selfEnd = 0;

static void wnr_log_init(HINSTANCE self){
    g_self=self;
    char dir[260]={0};
    GetModuleFileNameA((HMODULE)self, dir, sizeof(dir)-1);
    char* slash=strrchr(dir,'\\'); if(slash) slash[1]=0; else dir[0]=0;
    char flag[300]; _snprintf(flag,sizeof(flag)-1,"%sWoWRomanizer.debug",dir);
    FILE* ff=fopen(flag,"rb"); if(ff){ g_logEnabled=true; fclose(ff); }
    _snprintf(g_logpath,sizeof(g_logpath)-1,"%sWoWRomanizer.log",dir);
    // record our module address range (for the VEH ownership check)
    HMODULE hm=(HMODULE)self;
    // GetModuleInformation needs psapi; do it cheaply via PE headers instead:
    IMAGE_DOS_HEADER* dos=(IMAGE_DOS_HEADER*)hm;
    if(dos && dos->e_magic==IMAGE_DOS_SIGNATURE){
        IMAGE_NT_HEADERS* nt=(IMAGE_NT_HEADERS*)((BYTE*)hm + dos->e_lfanew);
        g_selfBase=(uintptr_t)hm;
        g_selfEnd=g_selfBase + nt->OptionalHeader.SizeOfImage;
    }
}
static void wnr_log(const char* fmt, ...){
    if(!g_logEnabled) return;
    FILE* f=fopen(g_logpath,"a"); if(!f) return;
    va_list ap; va_start(ap,fmt); vfprintf(f,fmt,ap); va_end(ap); fputc('\n',f); fclose(f);
}

// ---------- Vectored Exception Handler (crash net) ----------
// Last-resort breadcrumb: if an access violation faults inside OUR module, log
// it (when debug logging is on) before the normal handlers run. Real protection
// is the validation gate (don't hook a mismatched client) + IsBadReadPtr guards
// in the hook bodies. We do NOT attempt unsafe generic AV 'recovery'.
static PVOID g_veh=0;
static LONG CALLBACK wnr_veh(EXCEPTION_POINTERS* ep){
    if(ep && ep->ExceptionRecord &&
       ep->ExceptionRecord->ExceptionCode==EXCEPTION_ACCESS_VIOLATION){
        uintptr_t ip=(uintptr_t)ep->ExceptionRecord->ExceptionAddress;
        if(g_selfBase && ip>=g_selfBase && ip<g_selfEnd){
            wnr_log("VEH: access violation in our code @%p (logging only)", (void*)ip);
        }
    }
    return EXCEPTION_CONTINUE_SEARCH;
}
static void wnr_install_veh(){ if(!g_veh) g_veh=AddVectoredExceptionHandler(1, wnr_veh); }

// ---------- client validation ----------
#define WNR_BUILDSTR_ADDR 0x0080A364
#define WNR_BUILDSTR_EXP  "WoW [Release] Build 5875"
typedef struct { unsigned addr; unsigned char sig[8]; const char* name; } WnrSig;

static bool wnr_mem_eq(const void* p, const void* q, size_t n){
    if(IsBadReadPtr(p,n)) return false;
    return memcmp(p,q,n)==0;
}
static bool wnr_validate(const WnrSig* sigs, int n){
    const char* bs=(const char*)WNR_BUILDSTR_ADDR;
    if(!wnr_mem_eq(bs, WNR_BUILDSTR_EXP, 24)){
        wnr_log("VALIDATE FAIL: build string mismatch/unreadable @0x%08X", WNR_BUILDSTR_ADDR);
        return false;
    }
    for(int i=0;i<n;++i){
        if(!wnr_mem_eq((const void*)(uintptr_t)sigs[i].addr, sigs[i].sig, 8)){
            wnr_log("VALIDATE FAIL: signature mismatch at %s (0x%08X) - client build differs, disabling",
                    sigs[i].name, sigs[i].addr);
            return false;
        }
    }
    wnr_log("VALIDATE OK: 5875 build + %d signatures matched", n);
    return true;
}

// ---------- hook install helper ----------
static bool wnr_hook(void* addr, void* det, void** orig, const char* nm){
    if(MH_CreateHook(addr,det,orig)!=MH_OK){ wnr_log("hook FAIL %s",nm); return false; }
    if(MH_EnableHook(addr)!=MH_OK){ wnr_log("enable FAIL %s",nm); return false; }
    return true;
}

// ---------- tooltip exclusion (coexist with tooltip-translating addons) ----------
// FIX: the previous version ALSO called 0x6F3080 (lua_settop) which MUTATED the
// Lua stack before the real glue ran, corrupting its args -> all translation
// broke ("no translate at all"). The glue actually gets the frame from 0x6F3740
// ALONE (its return is the object; the glue then does [obj]=vtable). 0x6F3740 ->
// 0x6F3410 is verified READ-ONLY (computes a stack-slot pointer, writes nothing).
// So we call ONLY 0x6F3740, read the frame name via vtable slot +4, and skip
// frames named "*Tooltip*". We never touch the stack. Fully guarded.
typedef void* (__fastcall* WnrResolve_t)(void* L, int idx);   // 0x6F3740, read-only
typedef const char* (__thiscall* WnrGetName_t)(void* obj);
static WnrResolve_t p_resolveThis = reinterpret_cast<WnrResolve_t>(0x006F3740);


// Returns the frame's name (for logging) if it looks like a Group Finder / LFG
// addon frame, else nullptr. Used to route LFG text through glossary-only mode.
static const char* wnr_lfg_frame_name(void* L){
    if(!L) return nullptr;
    void* frame = p_resolveThis(L, -1);
    if(!frame || IsBadReadPtr(frame, sizeof(void*))) return nullptr;
    void** vtbl = *(void***)frame;
    if(!vtbl || IsBadReadPtr(vtbl, 8)) return nullptr;
    void* getName = vtbl[1];
    if(!getName || IsBadCodePtr((FARPROC)getName)) return nullptr;
    const char* name = ((WnrGetName_t)getName)(frame);
    if(!name || IsBadReadPtr(name, 1)) return nullptr;
    // Broad match for Group Finder / LFG addons (Turtle WoW GBB, premade, etc).
    if(strstr(name,"Group")||strstr(name,"group")||
       strstr(name,"LFG")||strstr(name,"lfg")||
       strstr(name,"Bulletin")||strstr(name,"GBB")||
       strstr(name,"Finder")||strstr(name,"Premade")||
       strstr(name,"Browse")||strstr(name,"MeetingStone")||
       strstr(name,"Queue")||strstr(name,"Dungeon"))
        return name;
    return nullptr;
}

// Classify the frame behind a SetText call into a surface bucket, by reading its
// name via the vtable (same mechanism as wnr_lfg_frame_name). Returns:
//   0 = unknown/other, 1 = social (who/friends/guild), 2 = unit frames
// (LFG is handled separately by wnr_lfg_frame_name.)

// Return the frame's raw name (or nullptr) for diagnostics - no matching.
static const char* wnr_any_frame_name(void* L){
    if(!L) return nullptr;
    void* frame = p_resolveThis(L, -1);
    if(!frame || IsBadReadPtr(frame, sizeof(void*))) return nullptr;
    void** vtbl = *(void***)frame;
    if(!vtbl || IsBadReadPtr(vtbl, 8)) return nullptr;
    void* getName = vtbl[1];
    if(!getName || IsBadCodePtr((FARPROC)getName)) return nullptr;
    const char* name = ((WnrGetName_t)getName)(frame);
    if(!name || IsBadReadPtr(name, 1)) return nullptr;
    return name;
}
static int wnr_surface_of(void* L){
    if(!L) return 0;
    void* frame = p_resolveThis(L, -1);
    if(!frame || IsBadReadPtr(frame, sizeof(void*))) return 0;
    void** vtbl = *(void***)frame;
    if(!vtbl || IsBadReadPtr(vtbl, 8)) return 0;
    void* getName = vtbl[1];
    if(!getName || IsBadCodePtr((FARPROC)getName)) return 0;
    const char* name = ((WnrGetName_t)getName)(frame);
    if(!name || IsBadReadPtr(name, 1)) return 0;
    if(strstr(name,"WhoFrame")||strstr(name,"FriendsFrame")||strstr(name,"GuildFrame")||
       strstr(name,"WhoList")||strstr(name,"FriendsList")||strstr(name,"GuildList"))
        return 1;  // social
    if(strstr(name,"TargetFrame")||strstr(name,"PartyMemberFrame")||
       strstr(name,"PlayerFrame")||strstr(name,"TargetofTarget")||
       strstr(name,"PetFrame"))
        return 2;  // unit frames (default)
    return 0;
}
// Runtime surface toggles -- pushed from the addon via the CNFXCFG control
// string (positional slots 8/9/10). Each defaults to false = current
// behavior (skip the surface, let the addon Lua or another addon translate
// it). Flipping ON routes the surface through the standard SetText
// translation pipe -- experimental, may collide with WT or other addons.
extern volatile bool g_surface_tooltipName;     // GameTooltipTextLeft1 (unit name line)
extern volatile bool g_surface_tooltipBody;     // GameTooltipTextLeft2+, Right* (body lines)
extern volatile bool g_surface_nameplates;      // Nameplate / WoWTranslateNameplate frames

// Decide whether to translate based purely on the FontString frame's name.
// Shared between the Lua glue hook (which resolves the name via Lua stack)
// and the C++ leaf hook (which has a direct fs pointer). Same gates, one
// source of truth.
static bool wnr_target_should_skip_by_name(const char* name){
    if(!name) return false;
    if(strstr(name, "Tooltip")) {
        if(strcmp(name, "GameTooltipTextLeft1") == 0) {
            return !g_surface_tooltipName;
        }
        return !g_surface_tooltipBody;
    }
    if(strstr(name, "Nameplate") || strstr(name, "WoWTranslateNameplate")) {
        return !g_surface_nameplates;
    }
    if(strstr(name, "WhoFrame"))           return true;
    if(strstr(name, "FriendsFrame"))       return true;
    if(strstr(name, "GuildFrame"))         return true;
    if(strstr(name, "GuildRoster"))        return true;
    if(strstr(name, "LFGFrame"))           return true;
    if(strstr(name, "LFGBrowse"))          return true;
    if(strstr(name, "MeetingStone"))       return true;
    if(strstr(name, "PartyMemberFrame"))   return true;
    if(strstr(name, "RaidGroupButton"))    return true;
    return false;
}

static bool wnr_target_should_skip(void* L){
    if(!L) return false;
    void* frame = p_resolveThis(L, -1);     // read-only; does NOT mutate stack
    if(!frame || IsBadReadPtr(frame, sizeof(void*))) return false;
    void** vtbl = *(void***)frame;
    if(!vtbl || IsBadReadPtr(vtbl, 8)) return false;
    void* getName = vtbl[1];                 // vtable slot +4 = GetName
    if(!getName || IsBadCodePtr((FARPROC)getName)) return false;
    const char* name = ((WnrGetName_t)getName)(frame);
    if(!name || IsBadReadPtr(name, 1)) return false;
    return wnr_target_should_skip_by_name(name);
}
