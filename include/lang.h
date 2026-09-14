#ifdef WLE_LANG_SPA
#include "Lang/SPA.LNG"
#endif

//#ifdef WLE_LANG_ENG
//#define CUSTOM_LNG
//#include "Lang/ENG.LNG"
//#endif

#ifndef CUSTOM_LNG
#include "Lang/CHS.LNG"  // A9VG汉化版：默认内置中文；ENG.LNG 仍可作为外部语言文件加载
#endif
