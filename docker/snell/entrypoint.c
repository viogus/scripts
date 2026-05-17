#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *env_or(const char *name, const char *fallback) {
  const char *v = getenv(name);
  return v ? v : fallback;
}

/* Read n bytes from /dev/urandom, return bytes actually read */
static int urandom_bytes(unsigned char *buf, int n) {
  int fd = open("/dev/urandom", O_RDONLY);
  if (fd < 0) return -1;
  ssize_t total = 0;
  while (total < n) {
    ssize_t r = read(fd, buf + total, n - total);
    if (r <= 0) break;
    total += r;
  }
  close(fd);
  return total;
}

static unsigned short random_port(void) {
  unsigned char buf[2];
  if (urandom_bytes(buf, 2) < 2) return 0;
  unsigned short val = ((unsigned short)buf[0] << 8) | buf[1];
  return (val % 64510) + 1025;
}

static void random_psk(char *out, int len) {
  static const char set[] =
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
  unsigned char buf[32];
  if (urandom_bytes(buf, sizeof(buf)) < (int)sizeof(buf)) {
    out[0] = '\0';
    return;
  }
  for (int i = 0; i < len; i++) out[i] = set[buf[i] % (sizeof(set) - 1)];
  out[len] = '\0';
}

static int is_help_or_version(const char *arg) {
  return !strcmp(arg, "-h") || !strcmp(arg, "--help") ||
         !strcmp(arg, "--version") || !strcmp(arg, "-V");
}

static int has_config_arg(int argc, char **argv) {
  for (int i = 0; i < argc; i++) {
    if (!strcmp(argv[i], "-c") || !strcmp(argv[i], "--config")) return 1;
    if (!strncmp(argv[i], "--config=", 9)) return 1;
  }
  return 0;
}

static int mkdir_p(const char *path) {
  char buf[4096], *p;
  struct stat st;
  size_t len;

  len = strlen(path);
  if (len >= sizeof(buf)) return -1;
  memcpy(buf, path, len + 1);

  for (p = buf + 1; *p; p++) {
    if (*p == '/') {
      *p = '\0';
      if (stat(buf, &st) != 0) {
        if (mkdir(buf, 0755) != 0 && errno != EEXIST) return -1;
      }
      *p = '/';
    }
  }
  if (stat(buf, &st) != 0) {
    if (mkdir(buf, 0755) != 0 && errno != EEXIST) return -1;
  }
  return 0;
}

int main(int argc, char **argv) {
  const char *conf_path = env_or("CONF", "/app/snell-server.conf");
  const char *bin = "/usr/local/bin/snell-server";
  struct stat st;

  /* Check for help/version: pass through without config generation */
  if (argc > 1 && is_help_or_version(argv[1])) {
    execv(bin, argv);
    perror("execv");
    return 1;
  }

  /* Generate config if file missing or empty, and not a directory */
  if (stat(conf_path, &st) != 0 || st.st_size == 0) {
    if (stat(conf_path, &st) == 0 && S_ISDIR(st.st_mode)) {
      fprintf(stderr, "[snell] config path is a directory: %s\n", conf_path);
      return 1;
    }

    const char *port_str = env_or("PORT", "");
    const char *psk = env_or("PSK", "");
    const char *obfs = env_or("OBFS", "off");
    const char *obfs_host = getenv("OBFS_HOST");

    unsigned short port = 0;
    if (port_str[0]) {
      char *end;
      long p = strtol(port_str, &end, 10);
      if (*end || p < 1 || p > 65535) {
        fprintf(stderr, "[snell] invalid PORT: %s\n", port_str);
        return 1;
      }
      port = (unsigned short)p;
    } else {
      port = random_port();
      if (!port) { perror("/dev/urandom"); return 1; }
    }

    char psk_buf[33] = {0};
    if (!psk[0]) {
      random_psk(psk_buf, 32);
      if (!psk_buf[0]) { perror("/dev/urandom"); return 1; }
      psk = psk_buf;
    }

    /* Ensure parent directory exists */
    {
      const char *slash = strrchr(conf_path, '/');
      if (slash && slash != conf_path) {
        char parent[4096];
        size_t plen = slash - conf_path;
        if (plen >= sizeof(parent)) return 1;
        memcpy(parent, conf_path, plen);
        parent[plen] = '\0';
        if (mkdir_p(parent) != 0) {
          fprintf(stderr, "[snell] mkdir_p(%s): %s\n", parent, strerror(errno));
          return 1;
        }
      }
    }

    fprintf(stderr, "[snell] generating config: %s\n", conf_path);

    FILE *f = fopen(conf_path, "w");
    if (!f) { perror("fopen"); return 1; }
    fprintf(f, "[snell-server]\n");
    fprintf(f, "listen = 0.0.0.0:%u\n", port);
    fprintf(f, "psk = %s\n", psk);

    if (strcmp(obfs, "off") != 0) {
      if (obfs_host) {
        fprintf(f, "obfs = %s\n", obfs);
        fprintf(f, "obfs-host = %s\n", obfs_host);
      } else {
        fprintf(stderr,
                "[snell] WARNING: OBFS=%s but OBFS_HOST not set, obfs "
                "disabled\n",
                obfs);
      }
    }
    fclose(f);
    fprintf(stderr, "[snell] port=%u psk=*** obfs=%s\n", port, obfs);
  }

  int inject_c = !has_config_arg(argc - 1, argv + 1);

  char **new_argv = calloc(argc + 3, sizeof(char *));
  if (!new_argv) { perror("calloc"); return 1; }
  int i = 0;
  new_argv[i++] = (char *)bin;
  if (inject_c) {
    new_argv[i++] = "-c";
    new_argv[i++] = (char *)conf_path;
  }
  for (int j = 1; j < argc; j++) new_argv[i++] = argv[j];
  new_argv[i] = NULL;

  execv(bin, new_argv);
  perror("execv");
  return 1;
}
