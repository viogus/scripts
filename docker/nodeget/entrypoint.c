#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

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
  const char *component, *config_path, *port, *log_filter, *db_url;
  FILE *f;
  char **new_argv;
  int i;

  component = getenv("NODEGET_COMPONENT");
  if (!component) component = "nodeget-server";

  config_path = getenv("NODEGET_CONFIG_PATH");
  if (!config_path) config_path = "/etc/nodeget/config.toml";

  port = getenv("NODEGET_PORT");
  if (!port) port = "2211";

  log_filter = getenv("NODEGET_LOG_FILTER");
  if (!log_filter) log_filter = "info";

  db_url = getenv("NODEGET_DATABASE_URL");
  if (!db_url) db_url = "sqlite:///var/lib/nodeget/nodeget.db?mode=rwc";

  if (access(config_path, F_OK) != 0) {
    if (strcmp(component, "nodeget-server") != 0) {
      fprintf(stderr,
              "[nodeget] agent requires a config file, mount one at %s\n",
              config_path);
      return 1;
    }

    fprintf(stderr, "[nodeget] generating config at %s\n", config_path);

    if (mkdir_p("/etc/nodeget") != 0 || mkdir_p("/var/lib/nodeget") != 0) {
      perror("mkdir");
      return 1;
    }

    f = fopen(config_path, "w");
    if (!f) {
      perror("fopen");
      return 1;
    }
    fprintf(f, "server_uuid = \"auto_gen\"\n");
    fprintf(f, "ws_listener = \"0.0.0.0:%s\"\n", port);
    fprintf(f, "\n[logging]\n");
    fprintf(f, "log_filter = \"%s\"\n", log_filter);
    fprintf(f, "\n[database]\n");
    fprintf(f, "database_url = \"%s\"\n", db_url);
    fclose(f);
  }

  new_argv = calloc(argc + 4, sizeof(char *));
  new_argv[0] = "/usr/bin/nodeget";
  new_argv[1] = "-c";
  new_argv[2] = (char *)config_path;
  for (i = 1; i < argc; i++) new_argv[i + 2] = argv[i];
  new_argv[argc + 2] = NULL;

  execv("/usr/bin/nodeget", new_argv);
  perror("execv");
  return 1;
}
