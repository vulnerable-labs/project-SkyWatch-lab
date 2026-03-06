#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>

#define MAX_PATH 512
#define DEFAULT_LOG "/var/log/skywatch/agent.log"

void get_config_log_path(char *log_path) {
    char config_path[MAX_PATH];
    const char *home = getenv("HOME");
    
    if (home == NULL) {
        strncpy(log_path, DEFAULT_LOG, MAX_PATH);
        return;
    }

    snprintf(config_path, sizeof(config_path), "%s/.skywatch.conf", home);

    FILE *fp = fopen(config_path, "r");
    if (!fp) {
        strncpy(log_path, DEFAULT_LOG, MAX_PATH);
        return;
    }

    char line[256];
    int in_logging_section = 0;
    
    while (fgets(line, sizeof(line), fp)) {
        // Remove newline
        line[strcspn(line, "\r\n")] = 0;
        
        if (strcmp(line, "[logging]") == 0) {
            in_logging_section = 1;
            continue;
        }
        
        if (line[0] == '[') {
            in_logging_section = 0;
            continue;
        }

        if (in_logging_section && strncmp(line, "path=", 5) == 0) {
            strncpy(log_path, line + 5, MAX_PATH);
            fclose(fp);
            return;
        }
    }
    
    fclose(fp);
    strncpy(log_path, DEFAULT_LOG, MAX_PATH);
}

void write_test_log(const char *log_path, const char *msg) {
    FILE *fp = fopen(log_path, "a");
    if (!fp) {
        fprintf(stderr, "Error: Could not open log file %s for writing.\n", log_path);
        // Note: In a real agent we might log to syslog on failure, but for the CTF this prints the error.
        return;
    }
    
    time_t rawtime;
    struct tm *timeinfo;
    char time_str[80];

    time(&rawtime);
    timeinfo = localtime(&rawtime);
    strftime(time_str, sizeof(time_str), "%Y-%m-%d %H:%M:%S", timeinfo);

    if (msg != NULL) {
        fprintf(fp, "%s\n", msg);
    } else {
        fprintf(fp, "[%s] [INFO] SkyWatch Agent test logging successful.\n", time_str);
    }
    fclose(fp);
    
    printf("Test log successfully written to: %s\n", log_path);
}

int main(int argc, char *argv[]) {
    if (argc > 1 && strcmp(argv[1], "--test") == 0) {
        char log_path[MAX_PATH];
        get_config_log_path(log_path);
        
        printf("SkyWatch Agent - Test Mode\n");
        printf("Resolved log path: %s\n", log_path);
        const char *msg = (argc > 2) ? argv[2] : NULL;
        write_test_log(log_path, msg);
        
        return 0;
    }

    // Normal operation mode simulation
    printf("SkyWatch Agent starting...\n");
    printf("Monitoring initialized. Use --test to verify log permissions.\n");
    printf("Running as UID: %d, EUID: %d\n", getuid(), geteuid());
    
    return 0;
}
