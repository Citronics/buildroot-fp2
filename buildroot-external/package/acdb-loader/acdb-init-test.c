/* Minimal ACDB loader init test */
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <unistd.h>

int main(int argc, char **argv) {
    const char *card = argc > 1 ? argv[1] : "msm8953-tasha-snd-card";
    
    void *lib = dlopen("libacdbloader.so", RTLD_NOW);
    if (!lib) {
        fprintf(stderr, "dlopen: %s\n", dlerror());
        return 1;
    }
    
    int (*init_v2)(const char*, const char*, int) = dlsym(lib, "acdb_loader_init_v2");
    if (!init_v2) {
        fprintf(stderr, "dlsym: %s\n", dlerror());
        return 1;
    }
    
    fprintf(stderr, "Calling acdb_loader_init_v2(\"%s\", NULL, 0)...\n", card);
    int ret = init_v2(card, NULL, 0);
    fprintf(stderr, "Result: %d\n", ret);
    
    if (ret == 0) {
        /* Try sending audio cal */
        void (*send_cal)(int, int) = dlsym(lib, "acdb_loader_send_audio_cal");
        if (send_cal) {
            fprintf(stderr, "Sending audio cal acdb_id=4 path=2...\n");
            send_cal(4, 2);
            fprintf(stderr, "Done\n");
        }
    }
    
    /* Keep running so cal stays loaded */
    fprintf(stderr, "ACDB loaded, press Ctrl+C to exit\n");
    pause();
    return 0;
}
