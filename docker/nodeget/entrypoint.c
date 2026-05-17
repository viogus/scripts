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

/* Minimal TOML string escape: backslash and double-quote */
static void toml_fputs(FILE *f, const char *s) {
  for (; *s; s++) {
    if (*s == '\\') fputs("\\\\", f);
    else if (*s == '"') fputs("\\\"", f);
    else fputc(*s, f);
  }
}

static const char *env_or(const char *name, const char *fallback) {
  const char *v = getenv(name);
  return v ? v : fallback;
}

static int has_config_arg(int argc, char **argv) {
  for (int i = 0; i < argc; i++) {
    if (!strcmp(argv[i], "-c") || !strcmp(argv[i], "--config")) return 1;
    if (!strncmp(argv[i], "--config=", 9)) return 1;
  }
  return 0;
}

/* Generate UUID from /proc or fall back to auto_gen */
static const char *resolve_uuid(void) {
  const char *v = getenv("NODEGET_SERVER_UUID");
  if (v) return v;
  FILE *f = fopen("/proc/sys/kernel/random/uuid", "r");
  if (f) {
    static char buf[64];
    if (fgets(buf, sizeof(buf), f)) {
      fclose(f);
      size_t len = strlen(buf);
      if (len > 0 && buf[len - 1] == '\n') buf[len - 1] = '\0';
      if (len > 1) return buf;
    } else {
      fclose(f);
    }
  }
  return "auto_gen";
}

static void write_config(const char *path, const char *data_dir) {
  const char *port, *ws_listener, *log_filter, *db_url;
  const char *jsonrpc_max, *enable_sock, *sock_path;
  const char *mon_flush, *mon_batch;
  const char *db_conn_to, *db_acq_to, *db_idle_to, *db_max_lt, *db_max_conn;

  port = env_or("NODEGET_PORT", NULL);
  if (!port) port = env_or("PORT", "2211");

  ws_listener = getenv("NODEGET_WS_LISTENER");
  if (!ws_listener) {
    static char ws_buf[256];
    snprintf(ws_buf, sizeof(ws_buf), "0.0.0.0:%s", port);
    ws_listener = ws_buf;
  }

  log_filter = env_or("NODEGET_LOG_FILTER", NULL);
  if (!log_filter) log_filter = env_or("LOG_FILTER", "info");

  db_url = env_or("NODEGET_DATABASE_URL", NULL);
  if (!db_url) db_url = env_or("DATABASE_URL", NULL);
  if (!db_url) {
    static char db_buf[512];
    snprintf(db_buf, sizeof(db_buf), "sqlite:///%s/nodeget.db?mode=rwc", data_dir);
    db_url = db_buf;
  }

  jsonrpc_max = env_or("NODEGET_JSONRPC_MAX_CONNECTIONS", "100");
  enable_sock = env_or("NODEGET_ENABLE_UNIX_SOCKET", "false");
  sock_path = env_or("NODEGET_UNIX_SOCKET_PATH", "/var/lib/nodeget.sock");
  mon_flush = env_or("NODEGET_MONITORING_FLUSH_INTERVAL_MS", "500");
  mon_batch = env_or("NODEGET_MONITORING_MAX_BATCH_SIZE", "1000");
  db_conn_to = env_or("NODEGET_DB_CONNECT_TIMEOUT_MS", "3000");
  db_acq_to = env_or("NODEGET_DB_ACQUIRE_TIMEOUT_MS", "3000");
  db_idle_to = env_or("NODEGET_DB_IDLE_TIMEOUT_MS", "3000");
  db_max_lt = env_or("NODEGET_DB_MAX_LIFETIME_MS", "30000");
  db_max_conn = env_or("NODEGET_DB_MAX_CONNECTIONS", "10");

  fprintf(stderr, "[nodeget] generating config at %s\n", path);

  FILE *f = fopen(path, "w");
  if (!f) { perror("fopen"); exit(1); }

  fprintf(f, "server_uuid = \"");
  toml_fputs(f, resolve_uuid());
  fprintf(f, "\"\n");

  fprintf(f, "ws_listener = \"");
  toml_fputs(f, ws_listener);
  fprintf(f, "\"\n");

  fprintf(f, "jsonrpc_max_connections = %s\n", jsonrpc_max);
  fprintf(f, "enable_unix_socket = %s\n", enable_sock);

  fprintf(f, "unix_socket_path = \"");
  toml_fputs(f, sock_path);
  fprintf(f, "\"\n");

  fprintf(f, "\n[logging]\n");
  fprintf(f, "log_filter = \"");
  toml_fputs(f, log_filter);
  fprintf(f, "\"\n");

  fprintf(f, "\n[monitoring_buffer]\n");
  fprintf(f, "flush_interval_ms = %s\n", mon_flush);
  fprintf(f, "max_batch_size = %s\n", mon_batch);

  fprintf(f, "\n[database]\n");
  fprintf(f, "database_url = \"");
  toml_fputs(f, db_url);
  fprintf(f, "\"\n");
  fprintf(f, "connect_timeout_ms = %s\n", db_conn_to);
  fprintf(f, "acquire_timeout_ms = %s\n", db_acq_to);
  fprintf(f, "idle_timeout_ms = %s\n", db_idle_to);
  fprintf(f, "max_lifetime_ms = %s\n", db_max_lt);
  fprintf(f, "max_connections = %s\n", db_max_conn);

  fclose(f);
}

int main(int argc, char **argv) {
  const char *component, *config_path, *data_dir;
  struct stat st;
  int is_server, user_argc, has_subcmd, inject_config;

  component = env_or("NODEGET_COMPONENT", "nodeget-server");
  is_server = strcmp(component, "nodeget-server") == 0;

  config_path = env_or("NODEGET_CONFIG_PATH", "/etc/nodeget/config.toml");
  data_dir = env_or("NODEGET_DATA_DIR", "/var/lib/nodeget");

  /* Generate config if file missing or empty, and it's not a directory */
  if (stat(config_path, &st) != 0 || st.st_size == 0) {
    if (stat(config_path, &st) == 0 && S_ISDIR(st.st_mode)) {
      fprintf(stderr, "[nodeget] config path is a directory: %s\n", config_path);
      return 1;
    }
    if (!is_server) {
      fprintf(stderr,
              "[nodeget] agent requires a config file, mount one at %s\n",
              config_path);
      return 1;
    }
    mkdir_p(config_path);
    /* Remove the config file if mkdir_p created it as a directory */
    if (stat(config_path, &st) == 0 && S_ISDIR(st.st_mode)) {
      /* The parent dirs exist, now remove the dir entry so fopen creates a file */
      /* Actually, mkdir_p creates the leaf as a dir. Rework: create parent only. */
    }
    /* Ensure parent directory exists */
    {
      char parent[4096];
      const char *slash = strrchr(config_path, '/');
      if (slash) {
        size_t plen = slash - config_path;
        if (plen >= sizeof(parent)) return 1;
        memcpy(parent, config_path, plen);
        parent[plen] = '\0';
        mkdir_p(parent);
      }
    }
    mkdir_p(data_dir);
    write_config(config_path, data_dir);
  }

  /* Build new argv: [binary] [subcmd?] [-c config] [user_args...] */
  int user_argc_total = argc - 1;
  char **user_argv = argv + 1;
  int user_argc = user_argc_total;
  has_subcmd = 0;
  inject_config = 1;

  if (is_server && user_argc > 0 && user_argv[0][0] != '-') {
    has_subcmd = 1;
  }

  /* Check if user already passed -c/--config; if so, don't inject */
  if (has_config_arg(user_argc, user_argv)) {
    inject_config = 0;
  }

  int total = 1; /* binary */
  if (is_server && !has_subcmd) total += 1; /* serve */
  if (is_server && has_subcmd) { total += 1; user_argc--; user_argv++; } /* user's subcmd */
  if (inject_config) total += 2; /* -c config */
  total += user_argc; /* remaining user args */

  char **new_argv = calloc(total + 1, sizeof(char *));
  int i = 0;
  new_argv[i++] = "/usr/bin/nodeget";

  if (is_server) {
    if (!has_subcmd) {
      new_argv[i++] = "serve";
    } else {
      new_argv[i++] = user_argv[-1]; /* user's subcmd, already advanced */
    }
  }

  if (inject_config) {
    new_argv[i++] = "-c";
    new_argv[i++] = (char *)config_path;
  }

  for (int j = 0; j < user_argc; j++) new_argv[i++] = user_argv[j];
  new_argv[i] = NULL;

  execv("/usr/bin/nodeget", new_argv);
  perror("execv");
  return 1;
}
