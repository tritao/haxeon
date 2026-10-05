#define HL_NAME(n) jitalloc_##n
#include <hl.h>
HL_API void hl_gc_set_profile_allocation_callback(void (*callback)(hl_type*,int,int,void*));
HL_API void hl_gc_census_start(int every);
HL_API void hl_gc_census_stop(void);
HL_API int hl_gc_get_flags(void);
HL_API void hl_gc_set_flags(int flags);
static int observed, census, tracking;
HL_API void hl_track_init(void);
HL_API void hl_track_set_bits(int flags,bool thread);
HL_API void hl_track_reset(void);
HL_API int hl_track_count(int *depth);
HL_API int hl_track_entry(int id,hl_type **type,int *count,int *info,varray *stack);
HL_API void hl_gc_census_dump(const char *filename);
static void callback(hl_type *type,int size,int allocated,void *caller) {
 (void)size; (void)allocated; (void)caller;
 if(type && type->kind==HOBJ && type->obj->name[0]=='N') observed++;
}
HL_PRIM void HL_NAME(mode)(int mode) {
 hl_track_init(); hl_track_set_bits(0,false); tracking=0;
 if(census) { hl_gc_census_dump(getenv("HL_JIT_ALLOC_CENSUS")); census=0; }
 hl_gc_set_profile_allocation_callback(NULL); hl_gc_census_stop();
 if(mode==1) hl_gc_set_profile_allocation_callback(callback);
 if(mode==2) { hl_gc_census_start(0); census=1; }
 if(mode==3) { hl_track_reset(); hl_track_set_bits(1,false); tracking=1; }
 observed=0;
}
HL_PRIM int HL_NAME(count)(void) {
 if(!tracking) return observed;
 int depth,count,info,total=0; hl_type *type;
 void *frames[1025]; varray stack={0}; stack.data=(vbyte*)frames;
 int entries=hl_track_count(&depth);
 for(int i=0;i<entries;i++) {
  hl_track_entry(i,&type,&count,&info,&stack);
  if(type && type->kind==HOBJ && type->obj->name[0]=='N') total+=count;
 }
 return total;
}
HL_PRIM void HL_NAME(major)(void) { hl_gc_major(); }
HL_PRIM bool HL_NAME(padding)(vdynamic *value) {
 unsigned int *tail=(unsigned int*)((char*)value+20);
 bool clean=*tail==0;
 *tail=0xa5a5a5a5;
 return clean;
}
DEFINE_PRIM(_BOOL,padding,_DYN);
DEFINE_PRIM(_VOID,mode,_I32);
DEFINE_PRIM(_I32,count,_NO_ARG);
DEFINE_PRIM(_VOID,major,_NO_ARG);
