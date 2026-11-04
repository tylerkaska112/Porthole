#include "itch_rar.h"
#include <stdio.h>
static int sink(void *c,int ev,uint32_t item,const char *name,int flags,uint64_t size,const void *d,size_t n){
  static uint64_t got; if(ev==IRAR_BEGIN){got=0;printf("  #%u %s flags=%d size=%llu\n",item,name,flags,(unsigned long long)size);}
  else if(ev==IRAR_DATA)got+=n; else printf("     end #%u read=%llu\n",item,(unsigned long long)got); return 0;}
int main(int argc,char**argv){ for(int i=1;i<argc;i++){ char r[200]={0}; printf("%s is_rar=%d\n",argv[i],irar_is_rar(argv[i]));
  int s=irar_list(argv[i],sink,0,r,sizeof r); printf(" list status=%d %s\n",s,r); r[0]=0;
  s=irar_extract(argv[i],sink,0,r,sizeof r); printf(" extract status=%d %s\n",s,r);} return 0;}
