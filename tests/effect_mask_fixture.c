/* GPL-3.0-or-later. Test-only EGL context; actual draw bindings and tgl state
 * macros are extracted from the pinned engine, never bundled in the addon. */
#define GL_GLEXT_PROTOTYPES
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <lua.h>
#include <lauxlib.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GL/gl.h>
#include <GL/glext.h>
#include "pinned_tgl.h"
#include "pinned_core_lua.h"
#include "pinned_auxiliar.c"

float gl_c_r=-1, gl_c_g=-1, gl_c_b=-1, gl_c_a=-1;
float gl_c_cr=-1, gl_c_cg=-1, gl_c_cb=-1, gl_c_ca=-1;
GLenum gl_c_texture_unit=GL_TEXTURE0;
GLuint gl_c_texture=0, gl_c_fbo=0, gl_c_shader=0, gl_tex_white=0;
int gl_c_vertices_nb=0, gl_c_texcoords_nb=0, gl_c_colors_nb=0, nb_draws=0;
GLfloat *gl_c_vertices_ptr=NULL, *gl_c_texcoords_ptr=NULL, *gl_c_colors_ptr=NULL;
bool fbo_active=true;
typedef int shader_type;
static void useShader(shader_type *s, ...) { abort(); }
#include "pinned_fbo.c"
#include "pinned_texture.c"
#include "pinned_vertex.c"

static EGLDisplay display;
static EGLContext context;
static EGLSurface surface;
static int init(lua_State *L) {
    PFNEGLGETPLATFORMDISPLAYEXTPROC get_platform=(void*)eglGetProcAddress("eglGetPlatformDisplayEXT");
    display=get_platform?get_platform(EGL_PLATFORM_SURFACELESS_MESA,EGL_DEFAULT_DISPLAY,NULL):eglGetDisplay(EGL_DEFAULT_DISPLAY);
    EGLint major,minor;
    if (!eglInitialize(display,&major,&minor)) return luaL_error(L,"eglInitialize failed: %x",eglGetError());
    if (!eglBindAPI(EGL_OPENGL_API)) return luaL_error(L,"eglBindAPI failed");
    EGLint cfgattr[]={EGL_SURFACE_TYPE,EGL_PBUFFER_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_BIT,EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,EGL_NONE};
    EGLConfig cfg; EGLint n;
    if (!eglChooseConfig(display,cfgattr,&cfg,1,&n)||n!=1) return luaL_error(L,"eglChooseConfig failed");
    EGLint surfattr[]={EGL_WIDTH,16,EGL_HEIGHT,16,EGL_NONE};
    surface=eglCreatePbufferSurface(display,cfg,surfattr);
    context=eglCreateContext(display,cfg,EGL_NO_CONTEXT,NULL);
    if (!eglMakeCurrent(display,surface,surface,context)) return luaL_error(L,"eglMakeCurrent failed");
    glViewport(0,0,16,16); glMatrixMode(GL_PROJECTION); glLoadIdentity(); glOrtho(0,16,16,0,-1001,1001);
    glMatrixMode(GL_MODELVIEW); glLoadIdentity();
    glEnableClientState(GL_VERTEX_ARRAY); glEnableClientState(GL_COLOR_ARRAY); glEnableClientState(GL_TEXTURE_COORD_ARRAY);
    glEnable(GL_TEXTURE_2D); glEnable(GL_BLEND); glBlendFunc(GL_SRC_ALPHA,GL_ONE_MINUS_SRC_ALPHA);
    lua_pushstring(L,(const char*)glGetString(GL_RENDERER)); return 1;
}
static int texture(lua_State *L) {
    size_t len; int w=luaL_checkint(L,1),h=luaL_checkint(L,2);
    const char *data=luaL_checklstring(L,3,&len);
    if (len != w*h*4) return luaL_error(L,"wrong texture bytes");
    GLuint *t=(GLuint*)lua_newuserdata(L,sizeof(GLuint)); auxiliar_setclass(L,"gl{texture}",-1);
    glGenTextures(1,t); tfglBindTexture(GL_TEXTURE_2D,*t);
    glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,w,h,0,GL_RGBA,GL_UNSIGNED_BYTE,data);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR); glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_REPEAT); glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_REPEAT);
    return 1;
}
static int pixels(lua_State *L) {
    lua_fbo *fbo=(lua_fbo*)auxiliar_checkclass(L,"gl{fbo}",1);
    GLint old; glGetIntegerv(GL_FRAMEBUFFER_BINDING,&old); glBindFramebufferEXT(GL_FRAMEBUFFER_EXT,fbo->fbo);
    size_t n=fbo->w*fbo->h*4; char *p=malloc(n); glReadPixels(0,0,fbo->w,fbo->h,GL_RGBA,GL_UNSIGNED_BYTE,p);
    lua_pushlstring(L,p,n); free(p); glBindFramebufferEXT(GL_FRAMEBUFFER_EXT,old); return 1;
}
static int state(lua_State *L) {
    GLfloat model[16],projection[16],clear[4],color[4]; GLint viewport[4],fbo,mode,unit,bound;
    glGetFloatv(GL_MODELVIEW_MATRIX,model); glGetFloatv(GL_PROJECTION_MATRIX,projection);
    glGetFloatv(GL_COLOR_CLEAR_VALUE,clear); glGetFloatv(GL_CURRENT_COLOR,color);
    glGetIntegerv(GL_VIEWPORT,viewport); glGetIntegerv(GL_FRAMEBUFFER_BINDING,&fbo); glGetIntegerv(GL_MATRIX_MODE,&mode);
    glGetIntegerv(GL_ACTIVE_TEXTURE,&unit); glGetIntegerv(GL_TEXTURE_BINDING_2D,&bound);
    lua_newtable(L);
    #define FIELD(name,value) lua_pushinteger(L,value); lua_setfield(L,-2,name)
    FIELD("fbo",fbo); FIELD("mode",mode); FIELD("unit",unit); FIELD("texture",bound); FIELD("blend",glIsEnabled(GL_BLEND));
    FIELD("error",glGetError()); FIELD("draws",nb_draws);
    #define BYTES(name,value) lua_pushlstring(L,(const char*)value,sizeof(value)); lua_setfield(L,-2,name)
    BYTES("model",model); BYTES("projection",projection); BYTES("clear",clear); BYTES("color",color); BYTES("viewport",viewport);
    return 1;
}
static int finish(lua_State *L) { glFinish(); return 0; }
static int unavailable(lua_State *L) { return 0; }
static int blend(lua_State *L) { if(lua_toboolean(L,1)) glEnable(GL_BLEND); else glDisable(GL_BLEND); return 0; }
int luaopen_effect_mask_fixture(lua_State *L) {
    static const luaL_Reg tex[]={{"__gc",sdl_free_texture},{"toScreen",sdl_texture_toscreen},{NULL,NULL}};
    static const luaL_Reg fbo[]={{"__gc",gl_free_fbo},{"toScreen",gl_fbo_toscreen},{"use",gl_fbo_use},{NULL,NULL}};
    static const luaL_Reg vo[]={{"__gc",gl_free_vertex},{"addPoint",gl_vertex_add},{"addQuad",gl_vertex_add_quad},{"toScreen",gl_vertex_toscreen},{NULL,NULL}};
    static const luaL_Reg methods[]={{"init",init},{"newTexture",texture},{"newFBO",gl_new_fbo},{"newVO",gl_new_vertex},{"pixels",pixels},{"state",state},{"finish",finish},{"blend",blend},{"unavailable",unavailable},{NULL,NULL}};
    auxiliar_newclass(L,"gl{texture}",tex); auxiliar_newclass(L,"gl{fbo}",fbo); auxiliar_newclass(L,"gl{vertexes}",vo);
    lua_newtable(L); luaL_register(L,NULL,methods); return 1;
}
