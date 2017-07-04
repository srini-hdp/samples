#include <libgen.h>
#include <dirent.h>
#include <fcntl.h>
#include <fts.h>
#include <errno.h>
#include <grp.h>
#include <unistd.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <pwd.h>

struct passwd *user_info = NULL;

static struct passwd* get_user_info(const char* user) {
  int string_size = sysconf(_SC_GETPW_R_SIZE_MAX);
  void* buffer = malloc(string_size + sizeof(struct passwd));
  struct passwd *result = NULL;
  if (getpwnam_r(user, buffer, buffer + sizeof(struct passwd), string_size, &result) != 0) {
    free(buffer);
    printf("Can't get user information %s - %s\n", user, strerror(errno));
    return NULL;
  }
  return result;
}

/*
 * gcc -o /usr/bin/switch-user switch-user.c
 * chown yarn:hadoop /usr/bin/switch-user
 * chmod 6050 /usr/bin/switch-user
 * ls -l /usr/bin/switch-user
 * ---Sr-s--- 1 root adm 9272 Jul  4 05:35 /usr/bin/switch-user
 * su someuser_belongs_to_hadoop_group
 * ./switch-user another_user
 */
int main(int argc, char **argv) {
    uid_t user = geteuid();
    gid_t group = getegid();
    printf("Current uid= %d, gid= %d\n", user, group);
    setuid(0);
    user = geteuid();
    printf("(should be 0) user= %d\n", user);
    if (argc > 1) {
        user_info = get_user_info(argv[1]);
        printf("Switching to uid= %d, gid= %d\n", user_info->pw_uid, user_info->pw_gid);
        initgroups(argv[1],user_info->pw_gid);
        free(user_info);
    }
    user = geteuid();
    group = getegid();
    printf("Current uid= %d, gid= %d\n", user, group);
    return 0;
}