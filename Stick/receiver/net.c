// The connection to the Mac: Tandem's MessageChannel and listener. Length-prefixed messages
// over one TCP connection, which only the Thunderbolt cable may bring.
#define _GNU_SOURCE
#include "tandem.h"

#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <unistd.h>

// Unplugging the cable doesn't close a TCP connection; it just goes quiet. Both ends send
// pings and give up after `silence_limit` seconds without hearing anything.
static const double ping_interval = 0.5;
static const double silence_limit = 3.0;

static struct net_handlers handlers;
static bool allow_any_interface;
static int listener = -1;

// Sending is shared between threads; the connection itself belongs to the network thread.
static pthread_mutex_t send_lock = PTHREAD_MUTEX_INITIALIZER;
static int connection = -1;

/// Linux calls the cable's network interface thunderbolt0 (macOS, bridge0).
static bool is_thunderbolt(const char *interface) { return strncmp(interface, "thunderbolt", 11) == 0; }

/// The interface a connection arrived on, from the address it reached us at.
static bool arrival_interface(int fd, char *name, size_t size) {
    struct sockaddr_in6 local;
    socklen_t length = sizeof local;
    if (getsockname(fd, (struct sockaddr *)&local, &length) != 0 || local.sin6_family != AF_INET6) return false;
    char index_name[IF_NAMESIZE];
    if (local.sin6_scope_id != 0 && if_indextoname(local.sin6_scope_id, index_name)) {
        snprintf(name, size, "%s", index_name);
        return true;
    }
    // Not link-local, so no scope: find which interface has that address.
    struct ifaddrs *all = NULL;
    if (getifaddrs(&all) != 0) return false;
    bool found = false;
    for (struct ifaddrs *i = all; i && !found; i = i->ifa_next) {
        if (!i->ifa_addr) continue;
        if (i->ifa_addr->sa_family == AF_INET6) {
            found = memcmp(&((struct sockaddr_in6 *)i->ifa_addr)->sin6_addr, &local.sin6_addr, 16) == 0;
        } else if (i->ifa_addr->sa_family == AF_INET && IN6_IS_ADDR_V4MAPPED(&local.sin6_addr)) {
            found = memcmp(&((struct sockaddr_in *)i->ifa_addr)->sin_addr, local.sin6_addr.s6_addr + 12, 4) == 0;
        }
        if (found) snprintf(name, size, "%s", i->ifa_name);
    }
    freeifaddrs(all);
    return found;
}

void net_link_description(char *out, size_t size) {
    DIR *dir = opendir("/sys/class/net");
    bool present = false, carrier = false;
    for (struct dirent *entry; dir && (entry = readdir(dir)) != NULL;) {
        if (!is_thunderbolt(entry->d_name)) continue;
        present = true;
        char path[300];
        snprintf(path, sizeof path, "/sys/class/net/%s/carrier", entry->d_name);
        FILE *file = fopen(path, "r");
        int value = 0;
        if (file && fscanf(file, "%d", &value) == 1 && value == 1) carrier = true;
        if (file) fclose(file);
    }
    if (dir) closedir(dir);
    snprintf(out, size, "%s", carrier ? "Thunderbolt cable connected" : present ? "Thunderbolt cable found, link not up yet" : "No Thunderbolt cable to a Mac yet");
}

bool net_send(uint8_t kind, const void *body, size_t count) {
    uint8_t header[5];
    wr32(header, (uint32_t)count);
    header[4] = kind;
    struct iovec parts[2] = { { header, 5 }, { (void *)body, count } };
    pthread_mutex_lock(&send_lock);
    bool ok = connection >= 0;
    size_t part = 0;
    while (ok && part < 2) {
        if (parts[part].iov_len == 0) { part++; continue; }
        ssize_t sent = writev(connection, parts + part, (int)(2 - part));
        if (sent < 0) {
            if (errno == EINTR) continue;
            ok = false;
            break;
        }
        size_t left = (size_t)sent;
        while (part < 2 && left >= parts[part].iov_len) left -= parts[part++].iov_len;
        if (part < 2) {
            parts[part].iov_base = (uint8_t *)parts[part].iov_base + left;
            parts[part].iov_len -= left;
        }
    }
    // A send that fails leaves the stream out of step: hang up, and the reader will see it.
    if (!ok && connection >= 0) shutdown(connection, SHUT_RDWR);
    pthread_mutex_unlock(&send_lock);
    return ok;
}

void net_drop(void) {
    pthread_mutex_lock(&send_lock);
    if (connection >= 0) shutdown(connection, SHUT_RDWR);
    pthread_mutex_unlock(&send_lock);
}

static void hang_up(void) {
    pthread_mutex_lock(&send_lock);
    int fd = connection;
    connection = -1;
    pthread_mutex_unlock(&send_lock);
    if (fd < 0) return;
    close(fd);
    handlers.disconnected();
}

/// Reads exactly `count` bytes, giving up if the Mac goes quiet for `silence_limit`.
static bool read_all(int fd, uint8_t *into, size_t count) {
    size_t have = 0;
    while (have < count) {
        ssize_t n = recv(fd, into + have, count - have, 0);
        if (n > 0) {
            have += (size_t)n;
        } else if (n == 0) {
            return false;
        } else if (errno != EINTR) {
            // EAGAIN: the receive timeout, i.e. silence in the middle of a message.
            return false;
        }
    }
    return true;
}

static void adopt(int fd, const char *from) {
    hang_up();
    int on = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof on);
    struct timeval limit = { .tv_sec = (time_t)silence_limit, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, sizeof limit);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, sizeof limit);
    pthread_mutex_lock(&send_lock);
    connection = fd;
    pthread_mutex_unlock(&send_lock);
    handlers.connected(from);
}

static void *net_thread(void *unused) {
    (void)unused;
    double last_heard = 0, last_ping = 0;
    for (;;) {
        int fd = connection; // only this thread changes it
        struct pollfd fds[2] = { { listener, POLLIN, 0 }, { fd, POLLIN, 0 } };
        poll(fds, fd >= 0 ? 2 : 1, 100);
        double now = now_seconds();

        if (fds[0].revents & POLLIN) {
            struct sockaddr_in6 peer;
            socklen_t length = sizeof peer;
            int accepted = accept4(listener, (struct sockaddr *)&peer, &length, SOCK_CLOEXEC);
            if (accepted >= 0) {
                char address[INET6_ADDRSTRLEN] = "?", interface[IF_NAMESIZE] = "?";
                inet_ntop(AF_INET6, &peer.sin6_addr, address, sizeof address);
                bool known = arrival_interface(accepted, interface, sizeof interface);
                // Turned away before it can replace the Mac already connected.
                if (!allow_any_interface && !(known && is_thunderbolt(interface))) {
                    log_line("refused a connection from %s on %s: not over Thunderbolt", address, interface);
                    close(accepted);
                } else {
                    char from[160];
                    snprintf(from, sizeof from, "%s on %s", address, interface);
                    adopt(accepted, from);
                    fd = accepted;
                    last_heard = last_ping = now;
                    continue;
                }
            }
        }
        if (fd < 0) continue;

        if (fds[1].revents & (POLLIN | POLLHUP | POLLERR)) {
            uint8_t header[5];
            bool ok = read_all(fd, header, 5);
            uint32_t length = ok ? rd32(header) : 0;
            uint8_t *body = NULL;
            if (ok && length > WIRE_MAX_MESSAGE) {
                log_line("message of %u bytes is too long, closing", length);
                ok = false;
            }
            if (ok && length > 0) {
                body = malloc(length);
                ok = body != NULL && read_all(fd, body, length);
            }
            if (!ok) {
                free(body);
                hang_up();
                continue;
            }
            last_heard = now_seconds();
            handlers.message(header[4], body, length);
        }

        now = now_seconds();
        if (now - last_heard > silence_limit) {
            log_line("nothing heard for %.1f s, closing", now - last_heard);
            hang_up();
            continue;
        }
        if (now - last_ping >= ping_interval) {
            last_ping = now;
            net_send(K_PING, NULL, 0);
        }
    }
    return NULL;
}

bool net_start(uint16_t port, bool any_interface, const struct net_handlers *callbacks) {
    handlers = *callbacks;
    allow_any_interface = any_interface;
    listener = socket(AF_INET6, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (listener < 0) return false;
    int on = 1, off = 0;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
    setsockopt(listener, IPPROTO_IPV6, IPV6_V6ONLY, &off, sizeof off);
    struct sockaddr_in6 address = { .sin6_family = AF_INET6, .sin6_port = htons(port), .sin6_addr = in6addr_any };
    if (bind(listener, (struct sockaddr *)&address, sizeof address) != 0 || listen(listener, 4) != 0) {
        log_line("couldn't listen on port %u: %s", port, strerror(errno));
        return false;
    }
    pthread_t thread;
    if (pthread_create(&thread, NULL, net_thread, NULL) != 0) return false;
    pthread_detach(thread);
    log_line("listening on port %u%s", port, any_interface ? " (any interface: testing)" : ", Thunderbolt only");
    return true;
}
