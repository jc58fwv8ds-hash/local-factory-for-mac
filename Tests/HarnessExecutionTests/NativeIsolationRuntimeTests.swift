import Foundation
import CryptoKit
import HarnessCore
import Testing

struct NativeIsolationRuntimeTests {
    @Test func operatingSystemAllowsScratchButDeniesOutsideProtectedNetworkAndCommands() async throws {
        let base = URL(fileURLWithPath: "/private/tmp/harness-native-isolation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let candidate = base.appendingPathComponent("candidate")
        let workspace = candidate.appendingPathComponent("workspace")
        let scratch = workspace.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let protected = workspace.appendingPathComponent("protected.txt")
        let credential = base.appendingPathComponent("fake-credential.txt")
        try "unchanged".write(to: protected, atomically: true, encoding: .utf8)
        try "synthetic-not-a-secret".write(to: credential, atomically: true, encoding: .utf8)
        let executable = workspace.appendingPathComponent("probe")
        let source = workspace.appendingPathComponent("probe.c")
        // Known host-authored diagnostic, not a model-generated build. Never touches real credentials.
        let program = """
        #include <stdio.h>
        #include <fcntl.h>
        #include <unistd.h>
        #include <stdlib.h>
        #include <spawn.h>
        #include <sys/socket.h>
        #include <netinet/in.h>
        #include <errno.h>
        extern char **environ;
        int main(void) {
            int failures = 0;
            int fd = open("\(scratch.path)/allowed", O_WRONLY|O_CREAT, 0600);
            if (fd < 0) failures++; else close(fd);
            fd = open("\(base.path)/outside", O_WRONLY|O_CREAT, 0600);
            if (fd >= 0) { failures++; close(fd); }
            fd = open("\(protected.path)", O_WRONLY|O_TRUNC);
            if (fd >= 0) { failures++; close(fd); }
            fd = open("\(credential.path)", O_RDONLY);
            if (fd >= 0) { failures++; close(fd); }
            const char *commands[] = {"/usr/bin/true", "/usr/bin/security", "/usr/bin/codesign", "/usr/sbin/installer"};
            for (int i=0;i<4;i++) {
                pid_t pid; char *argv[] = {(char*)commands[i], "--help", NULL};
                if (posix_spawn(&pid, commands[i], NULL, NULL, argv, environ) == 0) failures++;
            }
            int sock = socket(AF_INET, SOCK_STREAM, 0);
            if (sock >= 0) {
                struct sockaddr_in address = {0}; address.sin_family = AF_INET;
                address.sin_port = htons(9); address.sin_addr.s_addr = htonl(0x7f000001);
                errno = 0; int result = connect(sock, (struct sockaddr*)&address, sizeof(address));
                if (result == 0 || (errno != EPERM && errno != EACCES)) failures++;
                close(sock);
            } else if (errno != EPERM && errno != EACCES) failures++;
            if (getenv("OPENAI_API_KEY") != NULL || getenv("ANTHROPIC_API_KEY") != NULL) failures++;
            printf("isolation-probe-failures=%d\\n", failures);
            return failures == 0 ? 0 : 1;
        }
        """
        try program.write(to: source, atomically: true, encoding: .utf8)
        let compile = try await BoundedCommandRunner(timeout: .seconds(20)).run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["clang", source.path, "-o", executable.path],
            environment: ["DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"])
        #expect(compile.exitCode == 0)
        let digest = SHA256.hash(data: try Data(contentsOf: executable)).map { String(format: "%02x", $0) }.joined()
        let policy = IsolatedExecutionPolicy(candidate: candidate, workspace: workspace, scratch: scratch,
            executable: executable, executableHash: digest, protectedPaths: [protected])
        let result = try await NativeIsolatedExecutor().probe(policy)
        #expect(result.exitCode == 0)
        #expect(result.output.contains("isolation-probe-failures=0"))
        #expect(try String(contentsOf: protected, encoding: .utf8) == "unchanged")
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("outside").path))
        #expect(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("allowed").path))
    }
}
