/* GPL-3.0-or-later. Isolated driver for verbatim ToME particle-thread kernels.
 * No OpenGL calls or game saves. SDL mutexes, SFMT and Lua emitter callbacks are real.
 * Measures the worker's work in the calling thread; excludes scheduler/render contention.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <math.h>
#include <setjmp.h>
#include <SDL.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include "types.h"
#include "particles.h"
#include "SFMT.h"
#define rng(x,y) (x + rand_div(1 + y - x))
#define PARTICLE_ETERNAL 999999
#define ENGINE_POINTS 0
#define ENGINE_LINES 1
#define BLEND_NORMAL 0
#define BLEND_SHINY 1
#define BLEND_ADDITIVE 2
#define BLEND_MIXED 3
static int checked_pcall(lua_State *L,int n,int r,int e) {
    int code=lua_pcall(L,n,r,e);
    if(code) { fprintf(stderr,"Lua callback failed: %s\n",lua_tostring(L,-1)); exit(4); }
    return code;
}
#define lua_pcall checked_pcall
#include "kernels.inc"
static double cpu(void) { struct timespec t; clock_gettime(CLOCK_THREAD_CPUTIME_ID,&t); return t.tv_sec+t.tv_nsec/1e9; }
static double wall(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec/1e9; }
static void script(lua_State *L,const char *s) { if(luaL_loadstring(L,s)) { fprintf(stderr,"%s\n",lua_tostring(L,-1));exit(3); } lua_pcall(L,0,0,0); }
static uint64_t updates=0,slots=0;
static void tick(particle_thread *pt) {
    plist *l=pt->list,*prev=NULL;
    while(l) {
        if(l->ps && l->ps->alive && !l->ps->i_want_to_die) {
            if(l->ps->init) { updates++;slots+=l->ps->nb;thread_particle_run(pt,l); }
            else thread_particle_init(pt,l);
            prev=l;l=l->next;
        } else { plist *next=thread_particle_die(pt,l);if(prev)prev->next=next;else pt->list=next;l=next; }
    }
}
static int living(particle_thread *pt) { int n=0;for(plist *l=pt->list;l;l=l->next)if(l->ps->alive)n++;return n; }
static unsigned long long hash_bytes(unsigned long long h,const void *data,size_t size) {
    const unsigned char *b=data;
    for(size_t i=0;i<size;i++)h=(h^b[i])*1099511628211ULL;
    return h;
}
static unsigned long long digest(particles_type **pool,int n) {
    // Visual particle state and vertex buffers, excluding lifecycle flags.
    unsigned long long h=1469598103934665603ULL;
    for(int i=0;i<n;i++) { particles_type *p=pool[i];if(!p->init)continue;
        h=hash_bytes(h,p->particles,p->nb*sizeof(particle_type));
        h=hash_bytes(h,p->vertices,p->nb*8*sizeof(GLfloat));
        h=hash_bytes(h,p->colors,p->nb*16*sizeof(GLfloat));
        h=hash_bytes(h,p->texcoords,p->nb*8*sizeof(GLshort));
        h=hash_bytes(h,&p->rotate,sizeof(p->rotate));
        h=hash_bytes(h,&p->batch_nb,sizeof(p->batch_nb));
    }
    return h;
}
int main(int argc,char **argv) {
    if(argc!=7) { fprintf(stderr,"usage: particles fixture.lua definitions density keyframes purge_after_warm trace\n");return 2; }
    int density=atoi(argv[3]),frames=atoi(argv[4]),purge=atoi(argv[5]),trace=atoi(argv[6]);
    if(density<0 || density>100 || frames<1)return 2;
    if(SDL_Init(SDL_INIT_TIMER)!=0)return 2;
    init_gen_rand(42042);
    particle_thread pt={0};pt.L=luaL_newstate();luaL_openlibs(pt.L);pt.lock=SDL_CreateMutex();
    lua_State *L=pt.L;
    luaL_Reg rnglib[]={{"float",rng_float},{"range",rng_range},{NULL,NULL}};
    luaL_register(L,"rng",rnglib);lua_pop(L,1);
    script(L,"core={shader={active=function() return false end},particles={BLEND_SHINY=1,BLEND_NORMAL=0}}; __fcts={}");
    if(luaL_loadfile(L,argv[1])) { fprintf(stderr,"%s\n",lua_tostring(L,-1));return 2; } lua_pcall(L,0,1,0);
    int n=lua_objlen(L,-1);particles_type **pool=calloc(n,sizeof(*pool));
    int specs=luaL_ref(L,LUA_REGISTRYINDEX);
    double start=cpu();
    for(int i=1;i<=n;i++) {
        lua_rawgeti(L,LUA_REGISTRYINDEX,specs);lua_rawgeti(L,-1,i);
        lua_getfield(L,-1,"def");const char *def=lua_tostring(L,-1);
        char path[4096];snprintf(path,sizeof(path),"%s/%s.lua",argv[2],def);lua_pop(L,1);
        lua_getfield(L,-1,"args");char *args=strdup(lua_tostring(L,-1));lua_pop(L,3);
        particles_type *ps=calloc(1,sizeof(*ps));plist *l=calloc(1,sizeof(*l));pool[i-1]=ps;
        ps->lock=SDL_CreateMutex();ps->name_def=strdup(path);ps->args=args;ps->density=density;ps->alive=TRUE;ps->l=l;
        l->ps=ps;l->pt=&pt;l->emit_ref=l->updator_ref=l->generator_ref=LUA_NOREF;l->next=pt.list;pt.list=l;
        thread_particle_init(&pt,l);if(!ps->init){fprintf(stderr,"init failed %s\n",path);return 3;}
        if(lua_gettop(L)!=0){fprintf(stderr,"unbalanced Lua stack\n");return 3;}
    }
    double init_cpu=cpu()-start;
    // The fixture has only finite bursts plus continuous emitters; 200 frames exhaust all bursts.
    for(int i=0;i<200;i++){tick(&pt);if(trace && i<35)printf("TRACE %d %llu\n",i,digest(pool,n));}
    int warm_alive=living(&pt);
    if(purge){for(plist *l=pt.list;l;l=l->next)l->ps->i_want_to_die=TRUE;tick(&pt);}
    updates=slots=0;start=cpu();double wall_start=wall();
    for(int i=0;i<frames;i++)tick(&pt);
    double sec=cpu()-start,wall_sec=wall()-wall_start;
    printf("{\"emitters\":%d,\"density\":%d,\"frames\":%d,\"init_cpu_s\":%.9f,\"warm_alive\":%d,\"final_alive\":%d,\"updates\":%llu,\"update_slots\":%llu,\"cpu_s\":%.9f,\"wall_s\":%.9f,\"cpu_us_per_keyframe\":%.6f}\n",n,density,frames,init_cpu,warm_alive,living(&pt),(unsigned long long)updates,(unsigned long long)slots,sec,wall_sec,sec*1e6/frames);
    while(pt.list)pt.list=thread_particle_die(&pt,pt.list);
    for(int i=0;i<n;i++){SDL_DestroyMutex(pool[i]->lock);free(pool[i]);}free(pool);
    lua_close(L);SDL_DestroyMutex(pt.lock);SDL_Quit();return 0;
}
