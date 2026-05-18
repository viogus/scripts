#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *env_or(const char *name, const char *fallback) {
  const char *v = getenv(name);
  return (v && v[0]) ? v : fallback;
}

static int env_bool(const char *name) {
  const char *v = getenv(name);
  if (!v || !v[0]) return 0;
  return !strcmp(v, "1") || !strcmp(v, "true") || !strcmp(v, "yes");
}

static int is_help_or_version(const char *arg) {
  return !strcmp(arg, "-h") || !strcmp(arg, "--help") ||
         !strcmp(arg, "--version") || !strcmp(arg, "-v");
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

/* ---- TOML helpers ---- */

static void write_kv(FILE *f, const char *key, const char *val) {
  fprintf(f, "%s = \"%s\"\n", key, val);
}

static void write_opt_kv(FILE *f, const char *key, const char *env) {
  const char *v = getenv(env);
  if (v && v[0]) fprintf(f, "%s = \"%s\"\n", key, v);
}

static void write_opt_int(FILE *f, const char *key, const char *env) {
  const char *v = getenv(env);
  if (v && v[0]) fprintf(f, "%s = %s\n", key, v);
}

static void write_opt_bool(FILE *f, const char *key, const char *env, int fallback) {
  int v = env_bool(env);
  if (v != fallback) fprintf(f, "%s = %s\n", key, v ? "true" : "false");
}

/* ---- common blocks ---- */

static void write_log_block(FILE *f) {
  const char *level = env_or("FRP_LOG_LEVEL", "info");
  const char *file = getenv("FRP_LOG_FILE");
  const char *max_days = getenv("FRP_LOG_MAX_DAYS");

  fprintf(f, "log.level = \"%s\"\n", level);
  if (file) write_kv(f, "log.to", file); else fprintf(f, "log.to = \"console\"\n");
  fprintf(f, "log.maxDays = %s\n", max_days && max_days[0] ? max_days : "3");
}

static void write_auth_block(FILE *f) {
  const char *method = env_or("FRP_AUTH_METHOD", "token");
  const char *token = getenv("FRP_AUTH_TOKEN");
  const char *oidc_issuer = getenv("FRP_AUTH_OIDC_ISSUER");
  const char *oidc_audience = getenv("FRP_AUTH_OIDC_AUDIENCE");

  fprintf(f, "auth.method = \"%s\"\n", method);
  if (token) write_kv(f, "auth.token", token);

  if (!strcmp(method, "oidc") || oidc_issuer || oidc_audience) {
    if (oidc_issuer) write_kv(f, "auth.oidc.issuer", oidc_issuer);
    if (oidc_audience) write_kv(f, "auth.oidc.audience", oidc_audience);
    write_opt_kv(f, "auth.oidc.clientID", "FRP_AUTH_OIDC_CLIENT_ID");
    write_opt_kv(f, "auth.oidc.clientSecret", "FRP_AUTH_OIDC_CLIENT_SECRET");
    write_opt_kv(f, "auth.oidc.tokenEndpointURL", "FRP_AUTH_OIDC_TOKEN_URL");
    write_opt_bool(f, "auth.oidc.skipExpiryCheck", "FRP_AUTH_OIDC_SKIP_EXPIRY", 0);
    write_opt_bool(f, "auth.oidc.skipIssuerCheck", "FRP_AUTH_OIDC_SKIP_ISSUER", 0);
  }
}


/* ---- frps config ---- */

static int generate_frps_config(const char *path) {
  const char *bind_addr = env_or("FRP_BIND_ADDR", "0.0.0.0");
  const char *bind_port = env_or("FRP_BIND_PORT", "7000");

  FILE *f = fopen(path, "w");
  if (!f) { perror("fopen"); return -1; }

  write_kv(f, "bindAddr", bind_addr);
  fprintf(f, "bindPort = %s\n", bind_port);

  write_opt_int(f, "kcpBindPort", "FRP_KCP_BIND_PORT");
  write_opt_int(f, "quicBindPort", "FRP_QUIC_BIND_PORT");

  write_auth_block(f);

  /* transport */
  const char *tls_force = getenv("FRP_TLS_FORCE");
  const char *tls_cert = getenv("FRP_TLS_CERT_FILE");
  const char *tls_key = getenv("FRP_TLS_KEY_FILE");
  const char *tls_ca = getenv("FRP_TLS_CA_FILE");

  if (tls_force || tls_cert || tls_key || tls_ca) {
    fprintf(f, "transport.tls.force = %s\n", env_or("FRP_TLS_FORCE", "false"));
    if (tls_cert) write_kv(f, "transport.tls.certFile", tls_cert);
    if (tls_key)  write_kv(f, "transport.tls.keyFile", tls_key);
    if (tls_ca)   write_kv(f, "transport.tls.trustedCaFile", tls_ca);
  }

  /* vhost */
  write_opt_int(f, "vhostHTTPPort", "FRP_VHOST_HTTP_PORT");
  write_opt_int(f, "vhostHTTPSPort", "FRP_VHOST_HTTPS_PORT");
  write_opt_kv(f, "subDomainHost", "FRP_SUBDOMAIN_HOST");

  /* dashboard */
  const char *dash_port = getenv("FRP_DASHBOARD_PORT");
  if (dash_port && dash_port[0]) {
    write_kv(f, "webServer.addr", env_or("FRP_DASHBOARD_ADDR", "0.0.0.0"));
    fprintf(f, "webServer.port = %s\n", dash_port);
    write_opt_kv(f, "webServer.user", "FRP_DASHBOARD_USER");
    write_opt_kv(f, "webServer.password", "FRP_DASHBOARD_PWD");
  }

  /* allow ports */
  const char *allow_ports = getenv("FRP_ALLOW_PORTS");
  if (allow_ports && allow_ports[0]) {
    fprintf(f, "allowPorts = [\n");
    char buf[4096];
    strncpy(buf, allow_ports, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';
    char *tok = strtok(buf, ",");
    while (tok) {
      while (*tok == ' ') tok++;
      char *dash = strchr(tok, '-');
      if (dash) {
        *dash = '\0';
        fprintf(f, "  { start = %s, end = %s },\n", tok, dash + 1);
      } else {
        fprintf(f, "  { single = %s },\n", tok);
      }
      tok = strtok(NULL, ",");
    }
    fprintf(f, "]\n");
  }

  write_opt_int(f, "maxPortsPerClient", "FRP_MAX_PORTS_PER_CLIENT");
  fprintf(f, "udpPacketSize = %s\n", env_or("FRP_UDP_PACKET_SIZE", "1500"));

  write_opt_bool(f, "enablePrometheus", "FRP_ENABLE_PROMETHEUS", 0);

  write_log_block(f);

  fclose(f);
  return 0;
}

/* ---- frpc proxy stanza ---- */

static void write_proxy(FILE *f, const char *tag) {
  char env_name[64], env_type[64], env_lip[64], env_lport[64], env_rport[64];
  char env_sub[64], env_domains[64];
  char env_bw[64], env_enc[64], env_comp[64];

  snprintf(env_name,  sizeof(env_name),  "FRP_TUNNEL%s_NAME", tag);
  snprintf(env_type,  sizeof(env_type),  "FRP_TUNNEL%s_TYPE", tag);
  snprintf(env_lip,   sizeof(env_lip),   "FRP_TUNNEL%s_LOCAL_IP", tag);
  snprintf(env_lport, sizeof(env_lport), "FRP_TUNNEL%s_LOCAL_PORT", tag);
  snprintf(env_rport, sizeof(env_rport), "FRP_TUNNEL%s_REMOTE_PORT", tag);
  snprintf(env_sub,   sizeof(env_sub),   "FRP_TUNNEL%s_SUBDOMAIN", tag);
  snprintf(env_domains, sizeof(env_domains), "FRP_TUNNEL%s_CUSTOM_DOMAINS", tag);
  snprintf(env_bw,    sizeof(env_bw),    "FRP_TUNNEL%s_BANDWIDTH_LIMIT", tag);
  snprintf(env_enc,   sizeof(env_enc),   "FRP_TUNNEL%s_USE_ENCRYPTION", tag);
  snprintf(env_comp,  sizeof(env_comp),  "FRP_TUNNEL%s_USE_COMPRESSION", tag);

  const char *name = getenv(env_name);
  const char *type = env_or(env_type, "tcp");
  const char *lport = getenv(env_lport);
  const char *rport = getenv(env_rport);

  if (!name || !name[0] || !lport || !lport[0]) return;

  int is_web = !strcmp(type, "http") || !strcmp(type, "https");
  if (!is_web && (!rport || !rport[0])) return;

  fprintf(f, "\n[[proxies]]\n");
  write_kv(f, "name", name);
  write_kv(f, "type", type);
  write_kv(f, "localIP", env_or(env_lip, "127.0.0.1"));
  fprintf(f, "localPort = %s\n", lport);
  if (!is_web) fprintf(f, "remotePort = %s\n", rport);

  const char *sub = getenv(env_sub);
  if (sub && sub[0]) write_kv(f, "subdomain", sub);

  const char *domains = getenv(env_domains);
  if (domains && domains[0]) {
    fprintf(f, "customDomains = [");
    char buf[4096];
    strncpy(buf, domains, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';
    char *tok = strtok(buf, ",");
    int first = 1;
    while (tok) {
      while (*tok == ' ') tok++;
      fprintf(f, "%s\"%s\"", first ? "" : ", ", tok);
      first = 0;
      tok = strtok(NULL, ",");
    }
    fprintf(f, "]\n");
  }

  const char *bw = getenv(env_bw);
  if (bw && bw[0]) {
    write_kv(f, "transport.bandwidthLimit", bw);
    fprintf(f, "transport.bandwidthLimitMode = \"client\"\n");
  }
  if (env_bool(env_enc))  fprintf(f, "transport.useEncryption = true\n");
  if (env_bool(env_comp)) fprintf(f, "transport.useCompression = true\n");
}

/* ---- frpc config ---- */

static int generate_frpc_config(const char *path) {
  const char *server_addr = env_or("FRP_SERVER_ADDR", "127.0.0.1");
  const char *server_port = env_or("FRP_SERVER_PORT", "7000");

  FILE *f = fopen(path, "w");
  if (!f) { perror("fopen"); return -1; }

  write_kv(f, "serverAddr", server_addr);
  fprintf(f, "serverPort = %s\n", server_port);

  write_opt_kv(f, "user", "FRP_USER");
  write_auth_block(f);

  /* transport */
  write_kv(f, "transport.protocol", env_or("FRP_TRANSPORT_PROTOCOL", "tcp"));

  const char *tls_enable = getenv("FRP_TLS_ENABLE");
  const char *tls_cert = getenv("FRP_TLS_CERT_FILE");
  const char *tls_key = getenv("FRP_TLS_KEY_FILE");
  const char *tls_ca = getenv("FRP_TLS_CA_FILE");
  const char *tls_sn = getenv("FRP_TLS_SERVER_NAME");
  const char *tls_insecure = getenv("FRP_TLS_INSECURE_SKIP_VERIFY");

  if (tls_enable || tls_cert || tls_key || tls_ca || tls_sn || tls_insecure) {
    fprintf(f, "transport.tls.enable = %s\n", env_or("FRP_TLS_ENABLE", "true"));
    if (tls_cert) write_kv(f, "transport.tls.certFile", tls_cert);
    if (tls_key)  write_kv(f, "transport.tls.keyFile", tls_key);
    if (tls_ca)   write_kv(f, "transport.tls.trustedCaFile", tls_ca);
    if (tls_sn)   write_kv(f, "transport.tls.serverName", tls_sn);
    if (tls_insecure) fprintf(f, "transport.tls.insecureSkipVerify = %s\n",
                              env_bool("FRP_TLS_INSECURE_SKIP_VERIFY") ? "true" : "false");
  }

  write_opt_kv(f, "transport.proxyURL", "FRP_PROXY_URL");
  fprintf(f, "loginFailExit = %s\n", env_or("FRP_LOGIN_FAIL_EXIT", "true"));
  fprintf(f, "udpPacketSize = %s\n", env_or("FRP_UDP_PACKET_SIZE", "1500"));

  write_log_block(f);

  /* proxies: up to 3 (tag "", "_2", "_3") */
  write_proxy(f, "");
  write_proxy(f, "_2");
  write_proxy(f, "_3");
  fclose(f);
  return 0;
}

/* ---- main ---- */

int main(int argc, char **argv) {
  const char *conf_path = env_or("FRP_CONF", "/app/frp.toml");
  const char *mode = env_or("FRP_MODE", "frps");
  const char *bin = "/usr/bin/frp";
  struct stat st;

  if (argc > 1 && is_help_or_version(argv[1])) {
    execv(bin, argv);
    perror("execv");
    return 1;
  }

  if (stat(conf_path, &st) != 0 || st.st_size == 0) {
    if (stat(conf_path, &st) == 0 && S_ISDIR(st.st_mode)) {
      fprintf(stderr, "[frp] config path is a directory: %s\n", conf_path);
      return 1;
    }

    /* ensure parent directory exists */
    const char *slash = strrchr(conf_path, '/');
    if (slash && slash != conf_path) {
      char parent[4096];
      size_t plen = slash - conf_path;
      if (plen >= sizeof(parent)) return 1;
      memcpy(parent, conf_path, plen);
      parent[plen] = '\0';
      if (mkdir_p(parent) != 0) {
        fprintf(stderr, "[frp] mkdir_p(%s): %s\n", parent, strerror(errno));
        return 1;
      }
    }

    fprintf(stderr, "[frp] generating config (%s mode): %s\n", mode, conf_path);

    int ret;
    if (!strcmp(mode, "frpc")) ret = generate_frpc_config(conf_path);
    else                        ret = generate_frps_config(conf_path);
    if (ret != 0) return ret;

    fprintf(stderr, "[frp] config generated\n");
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
